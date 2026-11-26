using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using UnityEngine;
using Object = UnityEngine.Object;

internal static class ClickMageProgression
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly FieldInfo ShopItems = typeof(TraderShopWindow).GetField("_itemList", PrivateInstance);
    private static readonly MethodInfo SelectShopItem = typeof(TraderShopWindow).GetMethod("SelectItem", PrivateInstance);
    private static readonly MethodInfo CanInteract = typeof(InteractableObject).GetMethod("CanInteract", PrivateInstance);
    private static readonly MethodInfo InteractEnabled = typeof(InteractableObject).GetMethod("InteractEnabled", PrivateInstance);
    private static readonly MethodInfo Interact = typeof(InteractableObject).GetMethod("Interact", PrivateInstance);
    private static readonly MethodInfo ResourceAvailable =
        typeof(SpawnedResourceManager).GetMethod("ResourceAvailable", PrivateInstance);
    private static readonly MethodInfo IsRecipeEventUnlocked =
        typeof(SpawnedResourceManager).GetMethod("IsRecipeEventUnlocked", PrivateInstance);
    private static readonly MethodInfo HasStoredResources =
        typeof(ResourceStorage).GetMethod("HasResourcesStored", PrivateInstance);

    internal static object Catalog()
    {
        var buildingManager = PlayerBuildingManager.Instance;
        var stock = SpawnedResourceManager.Instance;
        var trader = buildingManager.trader;
        var obelisk = FindObelisk(buildingManager);
        return new {
            resources = stock.unlockedResources.Select(v => v.ToString()).ToArray(),
            events = stock.unlockedRecipeEvents.Select(v => v.ToString()).ToArray(),
            trader = trader ? new {
                id = trader.GetInstanceID(),
                storageId = trader.resourceStorage.GetInstanceID(),
                selected = RecipeKey(trader.resourceShop.itemToSell),
                options = trader.allShopRecipes.Select(Recipe).ToArray()
            } : null,
            processors = ProcessorShops().Select(shop => new {
                id = shop.resourceProcessor.GetInstanceID(),
                selected = RecipeKey(shop.resourceProcessor.GetSelectedRecipe()),
                options = shop.recipes.Select(Recipe).ToArray()
            }).ToArray(),
            blueprints = buildingManager.GetPlayerBlueprints().Select(state => new {
                type = state.blueprintSO.buildablePrefab.buildingType.ToString(),
                unlocked = state.unlocked, bought = state.recipeBought,
                cost = Cost(state.blueprintSO.neededResources)
            }).ToArray(),
            obelisk = obelisk ? new {
                id = obelisk.GetInstanceID(), storageId = obelisk.resourceStorage.GetInstanceID(),
                selected = obelisk.selectedUpgradeToBuy ? obelisk.selectedUpgradeToBuy.playerUpgradeType.ToString() : null,
                options = PlayerUpgradeManager.Instance.GetPlayerUpgrades().Select(upgrade => new {
                    type = upgrade.upgradeSO.playerUpgradeType.ToString(),
                    unlocked = upgrade.unlocked,
                    level = upgrade.currentLevel, maxLevel = upgrade.GetMaxLevel(),
                    cost = upgrade.currentLevel < upgrade.GetMaxLevel()
                        ? Cost(upgrade.upgradeSO.upgradeLevels[upgrade.currentLevel].neededResourcesForNextLevel)
                        : null
                }).ToArray()
            } : null,
            portals = Object.FindObjectsByType<Portal>(FindObjectsSortMode.InstanceID).Select(portal => new {
                id = portal.GetInstanceID(), storageId = portal.resourceStorage.GetInstanceID(),
                stage = portal.builtStage, finished = portal.IsFinished(),
                stages = portal.stages.Select((stage, number) => new {
                    stage = number, cost = Cost(stage.neededResourcesToUpgrade)
                }).ToArray()
            }).ToArray()
        };
    }

    internal static object SelectRecipe(PlayerInputManager input, int targetId, string recipeKey)
    {
        if (string.IsNullOrWhiteSpace(recipeKey))
            throw new ArgumentException("Supply a stock recipe key from the catalog.");

        var trader = PlayerBuildingManager.Instance.trader;
        if (trader && trader.GetInstanceID() == targetId)
        {
            var recipe = FindRecipe(trader.allShopRecipes, recipeKey);
            var resourceShop = trader.resourceShop;
            if (resourceShop.itemToSell != recipe)
            {
                if (ContainsStoredResources(resourceShop.resourceStorage))
                    throw new InvalidOperationException("The trader has a partially paid order. Finish or refund it first.");
                ConfirmRecipe(trader, trader.shopWindow, recipe);
            }
            return new { id = targetId, selected = RecipeKey(resourceShop.itemToSell) };
        }

        var shop = ProcessorShops().FirstOrDefault(candidate => candidate.resourceProcessor.GetInstanceID() == targetId);
        if (!shop)
            throw new ArgumentException("No active trader or processor with this instance ID.");

        var processor = shop.resourceProcessor;
        var processorRecipe = FindRecipe(shop.recipes, recipeKey);
        if (processor.GetSelectedRecipe() != processorRecipe)
        {
            if (processor.GetProcessing())
                throw new InvalidOperationException("The processor is still running. Let it finish its current recipe.");
            ConfirmRecipe(shop, shop.shopWindow, processorRecipe);
        }
        return new { id = targetId, selected = RecipeKey(processor.GetSelectedRecipe()) };
    }

    internal static object SelectUpgrade(PlayerInputManager input, string upgrade)
    {
        var obelisk = FindObelisk(PlayerBuildingManager.Instance);
        if (!obelisk || !obelisk.isActiveAndEnabled)
            throw new InvalidOperationException("The obelisk is unavailable.");

        var target = PlayerUpgradeManager.Instance.GetPlayerUpgrades().FirstOrDefault(option =>
            string.Equals(option.upgradeSO.playerUpgradeType.ToString(), upgrade, StringComparison.OrdinalIgnoreCase));
        if (target == null || !target.unlocked || target.currentLevel >= target.GetMaxLevel())
            throw new ArgumentException("The requested upgrade is locked, unknown, or at maximum level.");

        if (obelisk.selectedUpgradeToBuy != target.upgradeSO)
        {
            if (ContainsStoredResources(obelisk.resourceStorage))
                throw new InvalidOperationException("The obelisk has a partially paid upgrade. Finish or refund it first.");
            RequireInteractable(obelisk);
            obelisk.SetUpgradeToBuy(target.upgradeSO.playerUpgradeType);
        }

        return new {
            id = obelisk.GetInstanceID(), selected = obelisk.selectedUpgradeToBuy.playerUpgradeType.ToString(),
            level = target.currentLevel, storageId = obelisk.resourceStorage.GetInstanceID()
        };
    }

    private static object Recipe(ResourceRecipeSO recipe)
    {
        bool bought = IsBought(recipe);
        return new {
            key = RecipeKey(recipe), resource = recipe.resourceToGet.ToString(), @event = recipe.eventName.ToString(),
            needsEvent = recipe.neededEventUnlock.ToString(), needsResource = recipe.resourceNeededUnlock.ToString(),
            cost = Cost(recipe.neededResources), available = HasRecipeRequirements(recipe) && !bought,
            bought, seconds = recipe.timeToProcess
        };
    }

    private static object Cost(IEnumerable<NeededResource> ingredients)
    {
        return ingredients.Select(v => new { type = v.resourceType.ToString(), count = v.amountNeeded }).ToArray();
    }

    private static string RecipeKey(ResourceRecipeSO recipe)
    {
        return recipe ? recipe.name : null;
    }

    private static ResourceRecipeSO FindRecipe(IEnumerable<ResourceRecipeSO> recipes, string key)
    {
        var match = recipes.SingleOrDefault(recipe => recipe && string.Equals(RecipeKey(recipe), key, StringComparison.Ordinal));
        if (!match)
            throw new ArgumentException("No stock recipe with this key at the requested shop.");
        return match;
    }

    private static bool HasRecipeRequirements(ResourceRecipeSO recipe)
    {
        var stock = SpawnedResourceManager.Instance;
        return (bool)IsRecipeEventUnlocked.Invoke(stock, new object[] { recipe.neededEventUnlock }) &&
            (bool)ResourceAvailable.Invoke(stock, new object[] { recipe.resourceNeededUnlock });
    }

    private static bool IsBought(ResourceRecipeSO recipe)
    {
        return recipe.resourceToGet == ResourceType.eventResource &&
            (bool)IsRecipeEventUnlocked.Invoke(SpawnedResourceManager.Instance, new object[] { recipe.eventName });
    }

    private static void ConfirmRecipe(InteractableObject shop, TraderShopWindow window, ResourceRecipeSO recipe)
    {
        RequireInteractable(shop);
        var items = (List<ShopItemUiElement>)ShopItems.GetValue(window);
        var item = items?.SingleOrDefault(option => option && option.itemRecipe == recipe);
        if (!item || item.shopItemState != ShopItemState.available || !HasRecipeRequirements(recipe) || IsBought(recipe))
            throw new InvalidOperationException("The stock shop has not made this recipe available.");

        bool alreadyOpen = window.IsShopWindowOpen();
        if (!alreadyOpen)
            Interact.Invoke(shop, null);
        if (!window.IsShopWindowOpen())
            throw new InvalidOperationException("The stock shop did not open.");

        try
        {
            SelectShopItem.Invoke(window, new object[] { item, false });
            window.Confirm();
        }
        finally
        {
            if (!alreadyOpen && window.IsShopWindowOpen())
                window.Alternative();
        }
    }

    private static void RequireInteractable(InteractableObject shop)
    {
        if (!shop || !shop.isActiveAndEnabled || !(bool)CanInteract.Invoke(shop, null) ||
            !(bool)InteractEnabled.Invoke(shop, null))
            throw new InvalidOperationException("The stock interaction is unavailable.");
    }

    private static bool ContainsStoredResources(ResourceStorage storage)
    {
        return storage && (bool)HasStoredResources.Invoke(storage, null);
    }

    private static IEnumerable<ResourceProcessorShop> ProcessorShops()
    {
        return Object.FindObjectsByType<ResourceProcessorShop>(FindObjectsSortMode.InstanceID)
            .Where(shop => shop.isActiveAndEnabled && shop.resourceProcessor);
    }

    private static ObeliskInteractable FindObelisk(PlayerBuildingManager manager)
    {
        return manager.obelisk ? manager.obelisk.GetComponent<ObeliskInteractable>() : null;
    }
}
