using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using UnityEngine;
using Object = UnityEngine.Object;

internal static class ClickMageTransfer
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly Func<Resource, bool> IsCollectible =
        Bind<Resource, Func<Resource, bool>>("IsCollectible");
    private static readonly Action<PlayerCollect, Resource> AddToHand =
        Bind<PlayerCollect, Action<PlayerCollect, Resource>>("AddToHand");
    private static readonly Action<SpawnedResourceManager, Resource> MoveToHand =
        Bind<SpawnedResourceManager, Action<SpawnedResourceManager, Resource>>("MoveResourceToHand");
    private static readonly Action<PlayerCollect> DropResource =
        Bind<PlayerCollect, Action<PlayerCollect>>("DropResources");
    private static readonly Func<PlayerCollect, bool> IsDroppable =
        Bind<PlayerCollect, Func<PlayerCollect, bool>>("IsDroppableLocation");
    private static readonly Func<StorageBuilding, Vector3, Resource> TakeFromChest =
        Bind<StorageBuilding, Func<StorageBuilding, Vector3, Resource>>("GetResourceToHand");
    private static readonly Func<ResourceStorage, List<StoredResource>> Stored =
        Bind<ResourceStorage, Func<ResourceStorage, List<StoredResource>>>("GetStoredResources");
    private static readonly FieldInfo StorageActive = typeof(ResourceStorage).GetField("isActive", PrivateInstance);
    private static readonly FieldInfo FuelActive = typeof(FuelStorage).GetField("isActive", PrivateInstance);

    internal static object Ship(
        PlayerInputManager manager, Vector2 destination, ResourceType type, int count, string from,
        Vector2? source, float radius, Action<Vector2?> setCursor)
    {
        if (count < 1 || count > 40)
            throw new ArgumentOutOfRangeException(nameof(count));
        if ((!string.Equals(from, "Any", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(from, "Loose", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(from, "Chest", StringComparison.OrdinalIgnoreCase)))
            throw new ArgumentException("Choose Loose, Chest, or Any for the source.", nameof(from));
        if (!Finite(destination) || (source.HasValue &&
            (!Finite(source.Value) || !(radius > 0) || float.IsInfinity(radius))))
            throw new ArgumentException("The transfer coordinates and source radius must be finite.");

        var collect = manager.playerCollect;
        var held = collect.GetHeldResources();
        if (held.Count != 0 || collect.maxHandSize < 1)
            throw new InvalidOperationException("Empty the hand before starting a bulk transfer.");

        var stock = SpawnedResourceManager.Instance;
        int layer = LayerMask.NameToLayer("Resource");
        var receiver = new Receiver(Physics2D.OverlapPoint(destination, collect.storageLayerMask));
        bool allowLoose = !string.Equals(from, "Chest", StringComparison.OrdinalIgnoreCase);
        bool allowChests = !string.Equals(from, "Loose", StringComparison.OrdinalIgnoreCase);
        if (receiver.Fuel)
        {
            var prefab = PrefabManager.Instance.GetResourcePrefabForType(type);
            if (!prefab || !prefab.GetComponent<ResourceFuel>())
                return Result(count, 0, 0, 0, held.Count, "Destination does not accept this fuel");
        }

        int picked = 0;
        int delivered = 0;
        int onGround = 0;
        string reason = "Requested amount reached";
        setCursor(destination);
        try
        {
            if (!IsDroppable(collect))
                return Result(count, picked, delivered, onGround, held.Count, "Destination is blocked");

            var loose = allowLoose
                ? stock.spawnedResources.Where(resource =>
                    ValidLoose(resource, type, layer, source, radius, destination)).Take(count).ToArray()
                : Array.Empty<Resource>();
            int looseIndex = 0;
            var chests = Array.Empty<StorageBuilding>();
            bool lookedForChests = false;
            int chestIndex = 0;
            bool chestWait = false;
            while (picked < count)
            {
                if (Physics2D.OverlapPoint(destination, collect.storageLayerMask) != receiver.Collider)
                {
                    reason = "Destination changed";
                    break;
                }
                var slot = receiver.GetSlot(type);
                if (!receiver.HasRoom(type, slot, out reason))
                    break;
                int before = slot?.storedAmount ?? 0;
                int limit = slot?.storageLimit ?? 0;
                if (held.Count != 0 || collect.maxHandSize < 1 || !IsDroppable(collect))
                {
                    reason = "Destination is blocked or the hand became unavailable";
                    break;
                }

                Resource resource = null;
                while (looseIndex < loose.Length)
                {
                    var candidate = loose[looseIndex++];
                    if (ValidLoose(candidate, type, layer, source, radius, destination) &&
                        stock.spawnedResources.Contains(candidate))
                    {
                        resource = candidate;
                        break;
                    }
                }
                if (!resource && allowChests)
                {
                    if (!lookedForChests)
                    {
                        chests = Object.FindObjectsByType<StorageBuilding>(FindObjectsSortMode.InstanceID);
                        lookedForChests = true;
                    }
                    while (chestIndex < chests.Length)
                    {
                        var chest = chests[chestIndex++];
                        if (!chest || !chest.isActiveAndEnabled || chest == receiver.Chest ||
                            chest.storedResourceType != type || chest.storedAmount < 1)
                            continue;
                        var collider = chest.GetComponent<Collider2D>();
                        if (!collider || !collider.enabled)
                            continue;
                        var aim = (Vector2)collider.bounds.center;
                        if (!Within(aim, source, radius) || Physics2D.OverlapPoint(aim, collect.storageLayerMask) != collider)
                            continue;

                        // The native chest call checks its collection timer and debits its own saved stock.
                        resource = TakeFromChest(chest, aim);
                        chestWait |= chest.storedAmount > 0;
                        if (resource)
                            break;
                    }
                }
                if (!resource)
                {
                    reason = chestWait ? "Waiting for stock chest pickup cooldown" : "No matching source remains";
                    break;
                }
                if (resource.resourceType != type)
                {
                    reason = "Stock chest returned a different item";
                    break;
                }

                MoveToHand(stock, resource);
                AddToHand(collect, resource);
                picked++;

                var currentSlot = receiver.GetSlot(type);
                if (Physics2D.OverlapPoint(destination, collect.storageLayerMask) != receiver.Collider ||
                    currentSlot != slot || (slot != null &&
                        (slot.storedAmount != before || slot.storageLimit != limit)) ||
                    !IsDroppable(collect) || !receiver.HasRoom(type, currentSlot, out _))
                {
                    reason = "Destination changed after pickup";
                    break;
                }

                DropResource(collect);
                if (held.Count != 0)
                {
                    reason = "Stock placement left an item in hand";
                    break;
                }
                if (!receiver.StoresItems || !resource || resource.toBeDestroyed)
                    delivered++;
                else
                {
                    onGround++;
                    reason = "Destination rejected the delivery";
                    break;
                }

                // Paid orders and portal stages can consume inputs and replace storage inside the drop callback.
                if (slot != null && (receiver.GetSlot(type) != slot || slot.storedAmount != before + 1 ||
                    slot.storageLimit != limit))
                {
                    reason = "Destination advanced";
                    break;
                }
                reason = "Requested amount reached";
            }
        }
        finally
        {
            setCursor(null);
        }
        return Result(count, picked, delivered, onGround, held.Count, reason);
    }

    private static bool Finite(Vector2 point)
    {
        return !float.IsNaN(point.x) && !float.IsNaN(point.y) &&
            !float.IsInfinity(point.x) && !float.IsInfinity(point.y);
    }

    private static bool Within(Vector2 position, Vector2? source, float radius)
    {
        return !source.HasValue || (position - source.Value).sqrMagnitude <= radius * radius;
    }

    private static bool ValidLoose(Resource resource, ResourceType type, int layer, Vector2? source,
        float radius, Vector2 destination)
    {
        return resource && resource.resourceType == type && resource.isActiveAndEnabled &&
            !resource.toBeDestroyed && resource.gameObject.layer == layer && resource.ownCollider &&
            resource.ownCollider.enabled && IsCollectible(resource) &&
            Within(resource.transform.position, source, radius) &&
            ((Vector2)resource.transform.position - destination).sqrMagnitude > 0.3f;
    }

    private static object Result(int requested, int picked, int delivered, int onGround, int heldAfter, string reason)
    {
        return new { action = "ship", requested, picked, delivered, onGround, heldAfter, reason };
    }

    private static TDelegate Bind<TComponent, TDelegate>(string name) where TDelegate : class
    {
        return (TDelegate)(object)Delegate.CreateDelegate(typeof(TDelegate),
            typeof(TComponent).GetMethod(name, PrivateInstance));
    }

    private sealed class Receiver
    {
        internal readonly Collider2D Collider;
        internal readonly StorageBuilding Chest;
        internal readonly FuelStorage Fuel;
        private readonly ResourceStorage storage;

        internal Receiver(Collider2D collider)
        {
            Collider = collider;
            if (!collider)
                return;
            storage = collider.GetComponent<ResourceStorage>();
            if (!storage)
                Fuel = collider.GetComponent<FuelStorage>();
            if (!storage && !Fuel)
                Chest = collider.GetComponent<StorageBuilding>();
        }

        internal bool StoresItems => storage || Fuel || Chest;

        internal StoredResource GetSlot(ResourceType type)
        {
            return storage ? Stored(storage)?.FirstOrDefault(slot => slot.resourceType == type) : null;
        }

        internal bool HasRoom(ResourceType type, StoredResource slot, out string reason)
        {
            reason = null;
            if (storage && (!(bool)StorageActive.GetValue(storage) || slot == null))
                reason = "Destination does not accept this material";
            else if (storage && slot.storedAmount >= slot.storageLimit)
                reason = "Destination is full";
            else if (Fuel && !(bool)FuelActive.GetValue(Fuel))
                reason = "Destination fuel storage is inactive";
            else if (Fuel && Fuel.fuelList.Count >= Fuel.maxStorage)
                reason = "Destination fuel storage is full";
            else if (Chest && Chest.storedAmount >= 100)
                reason = "Destination is full";
            else if (Chest && Chest.storedAmount > 0 && Chest.storedResourceType != type)
                reason = "Destination does not accept this material";
            return reason == null;
        }
    }
}
