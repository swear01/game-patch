using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

public static class ClickMageControl
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly FieldInfo InputState = typeof(PlayerInputManager).GetField("_inputState", PrivateInstance);
    private static readonly FieldInfo ClickLayer = typeof(PlayerClick).GetField("_clickableLayerMask", PrivateInstance);
    private static readonly FieldInfo PauseState = typeof(PauseMenuController).GetField("isPaused", PrivateInstance);
    private static readonly FieldInfo StorageActive = typeof(ResourceStorage).GetField("isActive", PrivateInstance);
    private static readonly FieldInfo Placement = typeof(PlayerBuild).GetField("_blueprintToPlace", PrivateInstance);
    private static readonly FieldInfo MenuSaves = typeof(LoadWindowManager).GetField("campaignSaveDataList", PrivateInstance);
    private static readonly MethodInfo LoadCampaign = typeof(LoadWindowManager).GetMethod(
        "LoadSelectedSave", PrivateInstance, null, new[] { typeof(CampaignSaveData) }, null);
    private static readonly Action<PlayerClick, bool> Click = Bind<PlayerClick, Action<PlayerClick, bool>>("Click");
    private static readonly Action<PlayerCollect, bool> Collect = Bind<PlayerCollect, Action<PlayerCollect, bool>>("StartStopCollecting");
    private static readonly Action<PlayerCollect, bool> Drop = Bind<PlayerCollect, Action<PlayerCollect, bool>>("StartStopDropping");
    private static readonly Func<Resource, bool> IsCollectible = Bind<Resource, Func<Resource, bool>>("IsCollectible");
    private static readonly Func<ResourceStorage, List<StoredResource>> Stored =
        Bind<ResourceStorage, Func<ResourceStorage, List<StoredResource>>>("GetStoredResources");
    private static readonly Action<PlayerBuild, BuildingBlueprintSO> StartBuilding =
        Bind<PlayerBuild, Action<PlayerBuild, BuildingBlueprintSO>>("StartBuilding");
    private static readonly Action<PlayerBuild> PlaceBuilding = Bind<PlayerBuild, Action<PlayerBuild>>("Place");
    private static readonly int ProcessId = Process.GetCurrentProcess().Id;
    private static readonly string SessionId = Guid.NewGuid().ToString("N");
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClickMageControl", ProcessId.ToString());
    private static readonly string ReadyPath = Path.Combine(DirectoryPath, "ready.json");
    private static readonly string RequestPath = Path.Combine(DirectoryPath, "request.json");
    private static readonly string ResponsePath = Path.Combine(DirectoryPath, "response.json");
    private static readonly string EndingPath = Path.Combine(DirectoryPath, "ending.json");

    private static bool initialized;
    private static double nextPoll;
    private static float speed = 1;
    private static Vector2? cursor;
    private static Operation operation;
    private static ShippingBatch shippingBatch;
    private static object pendingReply;
    private static int loadingMenu;
    private static bool watch;
    private static Vector2? watchPoint;
    private static double nextWatchPoint;
    private static PlayerMove watchedMove;
    private static bool watchedEdgePan;

    private sealed class Operation
    {
        public string Id;
        public string Action;
        public string Input;
        public PlayerInputManager Manager;
        public Vector2 Point;
        public int Before;
        public int Clicks;
        public int Remaining;
        public int HandTarget;
        public ResourceType? Resource;
        public BuildingBlueprint Blueprint;
        public int StartFrame;
        public double FixedStart;
        public double EndsAt;
        public double NextClick;
    }

    private sealed class ShippingBatch
    {
        public string Id;
        public PlayerInputManager Manager;
        public int Scene;
        public int LastFrame;
        public JObject[] Transfers;
        public readonly List<object> Receipts = new List<object>();
    }

    private struct Shipment
    {
        public Vector2 Destination;
        public ResourceType Resource;
        public int Count;
        public string From;
        public Vector2? Source;
        public float Radius;
    }

    private static TDelegate Bind<TComponent, TDelegate>(string name) where TDelegate : class
    {
        return (TDelegate)(object)Delegate.CreateDelegate(typeof(TDelegate),
            typeof(TComponent).GetMethod(name, PrivateInstance));
    }

    public static Vector2 ResolveCursor(PlayerCursorManager original)
    {
        return cursor ?? original.GetCursorPosition();
    }

    public static bool HasCollectionCapacity(PlayerCollect collect)
    {
        return operation == null || operation.Action != "collect" || !cursor.HasValue ||
            collect.GetHeldResources().Count < operation.HandTarget;
    }

    public static Collider2D[] FilterCollectionCandidates(Collider2D[] candidates)
    {
        if (operation == null || operation.Action != "collect" || !cursor.HasValue || !operation.Resource.HasValue)
            return candidates;

        var type = operation.Resource.Value;
        return candidates.Where(candidate => {
            var resource = candidate.GetComponent<Resource>();
            return resource && resource.resourceType == type;
        }).ToArray();
    }

    public static void Tick(PlayerInputManager manager)
    {
        var now = Time.realtimeSinceStartupAsDouble;
        try
        {
            if (shippingBatch != null)
            {
                AdvanceShippingBatch(manager);
                Poll(now);
                return;
            }
            if (operation != null)
                Advance(manager);
            else
                UpdateWatch(manager);

            if (!Poll(now))
                return;
            if (speed != 1 && Time.timeScale == 1 && Ready(manager) && !Paused())
                Time.timeScale = speed;

            if (operation == null && File.Exists(RequestPath))
                ReadRequest(manager);
        }
        catch (Exception error)
        {
            if (shippingBatch != null)
                StopShippingBatch(error.GetBaseException().Message);
            else if (operation != null)
                Finish(error.GetBaseException().Message);
            // Keep gameplay running if local I/O is temporarily unavailable.
            nextPoll = now + 0.5;
            UnityEngine.Debug.LogWarning("ClickMageControl: " + error.GetBaseException().Message);
        }
    }

    public static void TickMenu(MainMenu menu)
    {
        if (!menu.loadWindow || PlayerInputManager.HasInstance)
            return;

        double now = Time.realtimeSinceStartupAsDouble;
        try
        {
            if (shippingBatch != null)
            {
                StopShippingBatch("The active campaign changed.");
                Poll(now);
                return;
            }
            if (Poll(now) && File.Exists(RequestPath))
                ReadRequest(null, menu);
        }
        catch (Exception error)
        {
            nextPoll = now + 0.5;
            UnityEngine.Debug.LogWarning("ClickMageControl menu: " + error.GetBaseException().Message);
        }
    }

    private static bool Poll(double now)
    {
        if (now < nextPoll)
            return false;
        nextPoll = now + 0.025;
        if (!initialized)
        {
            Directory.CreateDirectory(DirectoryPath);
            ClickMageEnding.TrackCompletion(status => WriteJson(EndingPath, new { session = SessionId, status }));
            WriteJson(ReadyPath, new { pid = ProcessId, protocol = 1, session = SessionId });
            initialized = true;
        }
        if (pendingReply != null)
        {
            WriteJson(ResponsePath, pendingReply);
            pendingReply = null;
        }
        return true;
    }

    private static void WriteJson(string path, object value)
    {
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonConvert.SerializeObject(value));
        if (File.Exists(path))
            File.Replace(temporary, path, null);
        else
            File.Move(temporary, path);
    }

    private static void ReadRequest(PlayerInputManager manager, MainMenu menu = null)
    {
        string json = File.ReadAllText(RequestPath);
        File.Delete(RequestPath);
        string id = null;
        try
        {
            var request = JObject.Parse(json);
            id = (string)request["id"];
            Guid parsedId;
            if (!Guid.TryParse(id, out parsedId))
                throw new ArgumentException("A request GUID is required.");
            if ((string)request["session"] != SessionId)
                throw new InvalidOperationException("The request belongs to a different game session.");
            var action = (string)request["action"];
            if (menu)
            {
                Reply(id, MenuAction(menu, request, action));
                return;
            }
            switch (action)
            {
                case "status": Reply(id, Status(manager)); return;
                case "ending": Reply(id, ClickMageEnding.Status()); return;
                case "continueending": Reply(id, ClickMageEnding.Advance()); return;
                case "render":
                    Reply(id, RenderOptions(request));
                    return;
                case "watch":
                    EnsureReady(manager);
                    SetWatchMode(manager, (bool?)request["enabled"] ?? true);
                    watchPoint = watch && request["x"] != null ? (Vector2?)TargetPoint(manager, request) : null;
                    nextWatchPoint = Time.realtimeSinceStartupAsDouble + 0.5;
                    if (watch) Application.runInBackground = true;
                    Reply(id, Status(manager));
                    return;
                case "catalog":
                    EnsureReady(manager);
                    Reply(id, ClickMageProgression.Catalog());
                    return;
                case "recipe":
                    EnsureAction(manager, null);
                    int? target = (int?)request["targetId"];
                    if (!target.HasValue) throw new ArgumentException("A recipe target ID is required.");
                    Reply(id, ClickMageProgression.SelectRecipe(manager, target.Value, (string)request["recipe"]));
                    return;
                case "upgrade":
                    EnsureAction(manager, null);
                    Reply(id, ClickMageProgression.SelectUpgrade(manager, (string)request["upgrade"]));
                    return;
                case "build":
                    StartBuild(manager, request, id);
                    return;
                case "ship":
                    Reply(id, DispatchShipment(manager, request));
                    return;
                case "shipbatch":
                    StartShippingBatch(manager, request["transfers"], id);
                    return;
                case "scan":
                    EnsureReady(manager);
                    Reply(id, Scan((string)request["kind"] ?? "all"));
                    return;
                case "speed":
                    EnsureReady(manager);
                    speed = Number(request, "multiplier", 1, 32);
                    if (Time.timeScale > 0 && !Paused())
                        Time.timeScale = speed;
                    Reply(id, Status(manager));
                    return;
                case "save":
                    EnsureAction(manager, null);
                    SaveManager.Instance.SaveGame(false);
                    Reply(id, new { counter = SaveManager.Instance.saveGameCounter });
                    return;
                case "click":
                case "collect":
                case "drop":
                    Start(manager, request, id, action);
                    return;
                default: throw new ArgumentException("Unknown action.");
            }
        }
        catch (Exception error)
        {
            if (operation != null)
                Finish(error.GetBaseException().Message);
            else
                Reply(id, null, error.GetBaseException().Message);
        }
    }

    private static object MenuAction(MainMenu menu, JObject request, string action)
    {
        if (action == "status")
            return new { ready = false, scene = "menu", loading = loadingMenu == menu.GetInstanceID() };
        if (action == "render")
            return RenderOptions(request);
        if (action != "saves" && action != "load")
            throw new InvalidOperationException("Load a campaign before issuing this action.");

        var saves = (List<CampaignSaveData>)MenuSaves.GetValue(menu.loadWindow);
        if (saves == null)
            throw new InvalidOperationException("The game is still reading the saves.");
        if (action == "saves")
            return new { saves = saves.Select(save => new {
                counter = save.saveGameCounter, name = save.saveGameName, lastPlayed = save.lastPlayed,
                autosave = save.isAutosave
            }).ToArray() };
        if (loadingMenu == menu.GetInstanceID())
            throw new InvalidOperationException("A campaign is already loading.");

        var counter = (int?)request["saveCounter"];
        string name = (string)request["saveName"];
        var matches = saves.Where(save => save.saveGameCounter == counter &&
            (name == null || string.Equals(save.saveGameName, name, StringComparison.Ordinal))).ToArray();
        if (matches.Length != 1)
            throw new ArgumentException("Choose a single matching save number and campaign name.");
        LoadCampaign.Invoke(menu.loadWindow, new object[] { matches[0] });
        loadingMenu = menu.GetInstanceID();
        return new { counter = matches[0].saveGameCounter, name = matches[0].saveGameName };
    }

    private static float Number(JObject request, string key, float min, float max)
    {
        var token = request[key];
        if (token == null || (token.Type != JTokenType.Integer && token.Type != JTokenType.Float))
            throw new ArgumentException(key + " must be a number.");
        float value = token.Value<float>();
        if (float.IsNaN(value) || value < min || value > max)
            throw new ArgumentOutOfRangeException(key);
        return value;
    }

    private static bool Paused()
    {
        return PauseMenuController.HasInstance && (bool)PauseState.GetValue(PauseMenuController.Instance);
    }

    private static object RenderOptions(JObject request)
    {
        if ((bool?)request["borderless"] == true)
            Screen.SetResolution(Display.main.systemWidth, Display.main.systemHeight, FullScreenMode.FullScreenWindow);
        else if ((bool?)request["windowed"] == true && Screen.fullScreen)
            Screen.SetResolution(1280, 720, FullScreenMode.Windowed);
        if (request["vsync"] != null)
            QualitySettings.vSyncCount = (int)Number(request, "vsync", 0, 2);
        if (request["maxFps"] != null)
            Application.targetFrameRate = (int)Number(request, "maxFps", 30, 480);
        return new { vsync = QualitySettings.vSyncCount, maxFps = Application.targetFrameRate,
            batchMode = Application.isBatchMode, mode = Screen.fullScreenMode.ToString(),
            fullscreen = Screen.fullScreen, width = Screen.width, height = Screen.height };
    }

    private static void ObservePoint(Vector2 point)
    {
        if (!watch || Time.realtimeSinceStartupAsDouble < nextWatchPoint)
            return;
        watchPoint = point;
        nextWatchPoint = Time.realtimeSinceStartupAsDouble + 1.1;
    }

    private static void SetWatchMode(PlayerInputManager manager, bool enabled)
    {
        if (watchedMove && (!enabled || watchedMove != manager.playerMove))
        {
            watchedMove.allowEdgePan = watchedEdgePan;
            watchedMove = null;
        }
        watch = enabled;
        if (!watch || watchedMove || !manager.playerMove)
            return;
        watchedMove = manager.playerMove;
        watchedEdgePan = watchedMove.allowEdgePan;
        watchedMove.allowEdgePan = false;
    }

    private static void UpdateWatch(PlayerInputManager manager)
    {
        if (!watch || !watchPoint.HasValue || !manager.playerMove || !manager.playerMove.playerBounds ||
            manager.ControlsDisabled() || Paused() || Time.deltaTime <= 0)
            return;
        var move = manager.playerMove;
        var target = move.playerBounds.ClosestPoint(watchPoint.Value);
        var offset = target - (Vector2)move.transform.position;
        if (offset.sqrMagnitude < 0.01f)
            return;
        float step = Mathf.Max(0.001f, move.moveSpeed * Time.deltaTime);
        move.Move(Vector2.ClampMagnitude(offset / step, 1));
    }

    private static ResourceType ParseResource(string filter)
    {
        ResourceType resource;
        if (!Enum.TryParse(filter, true, out resource) || !Enum.IsDefined(typeof(ResourceType), resource) ||
            !string.Equals(filter, resource.ToString(), StringComparison.OrdinalIgnoreCase) || resource == ResourceType.none)
            throw new ArgumentException("Unknown resource type.");
        return resource;
    }

    private static bool Ready(PlayerInputManager manager)
    {
        return manager && manager.playerCollect && manager.playerCollect.GetHeldResources() != null &&
            SaveManager.HasInstance && SaveManager.Instance.IsSavingEnabled() && Camera.main;
    }

    private static void EnsureReady(PlayerInputManager manager)
    {
        if (!Ready(manager))
            throw new InvalidOperationException("Load a campaign before issuing this action.");
    }

    private static void EnsureAction(PlayerInputManager manager, string input, PlayerInputState state = PlayerInputState.normal)
    {
        EnsureReady(manager);
        if (Paused() || Time.timeScale <= 0 || manager.ControlsDisabled() ||
            (PlayerInputState)InputState.GetValue(manager) != state)
            throw new InvalidOperationException("Gameplay controls are unavailable.");

        var actions = manager.playerInput.actions;
        if (input != null && actions.FindAction(input)?.enabled != true)
            throw new InvalidOperationException("The game has disabled " + input + ".");
        if (actions.FindAction("PlayerClick")?.IsPressed() == true ||
            actions.FindAction("Collect")?.IsPressed() == true ||
            actions.FindAction("Drop")?.IsPressed() == true)
            throw new InvalidOperationException("A physical gameplay input is active.");
    }

    private static Vector2 TargetPoint(PlayerInputManager manager, JObject request)
    {
        var point = new Vector2(Number(request, "x", -1000, 1000), Number(request, "y", -1000, 1000));
        var camera = Camera.main;
        var playerBounds = manager.playerMove.playerBounds;
        if (playerBounds)
        {
            var bounds = playerBounds.bounds;
            bounds.Expand(new Vector3(2 * camera.orthographicSize * camera.aspect, 2 * camera.orthographicSize, 0));
            if (point.x < bounds.min.x || point.x > bounds.max.x ||
                point.y < bounds.min.y || point.y > bounds.max.y)
                throw new ArgumentException("Target is outside the playable area.");
        }
        else if (!camera.pixelRect.Contains(camera.WorldToScreenPoint(point)))
            throw new ArgumentException("Target is outside the game view.");
        return point;
    }

    private static Shipment ReadShipment(PlayerInputManager manager, JObject request)
    {
        Vector2? source = null;
        if (request["sourceX"] != null || request["sourceY"] != null)
            source = new Vector2(Number(request, "sourceX", -1000, 1000), Number(request, "sourceY", -1000, 1000));
        string from = (string)request["from"] ?? "Any";
        if (!string.Equals(from, "Any", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(from, "Loose", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(from, "Chest", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Choose Loose, Chest, or Any for the source.");

        return new Shipment {
            Destination = TargetPoint(manager, request),
            Resource = ParseResource((string)request["resource"]),
            Count = (int)Number(request, "count", 1, 40),
            From = from, Source = source,
            Radius = request["sourceRadius"] == null ? 8 : Number(request, "sourceRadius", 0.1f, 1000)
        };
    }

    private static void EnsureShippingAllowed(PlayerInputManager manager)
    {
        EnsureAction(manager, "Collect");
        EnsureAction(manager, "Drop");
    }

    private static object DispatchShipment(PlayerInputManager manager, JObject request)
    {
        EnsureShippingAllowed(manager);
        var shipment = ReadShipment(manager, request);
        ObservePoint(shipment.Destination);
        try
        {
            return ClickMageTransfer.Ship(manager, shipment.Destination, shipment.Resource, shipment.Count,
                shipment.From, shipment.Source, shipment.Radius,
                point => cursor = point.HasValue ? (Vector2?)Camera.main.WorldToScreenPoint(point.Value) : null);
        }
        finally
        {
            cursor = null;
        }
    }

    private static void StartShippingBatch(PlayerInputManager manager, JToken transfersToken, string id)
    {
        var array = transfersToken as JArray;
        if (array == null || array.Count < 1 || array.Count > 12)
            throw new ArgumentException("Supply a transfers array with 1 to 12 shipment objects.");

        EnsureShippingAllowed(manager);
        var transfers = new JObject[array.Count];
        for (int i = 0; i < transfers.Length; i++)
        {
            var transfer = array[i] as JObject;
            if (transfer == null)
                throw new ArgumentException("Transfer " + i + " must be a shipment object.");
            if (transfer["count"]?.Type != JTokenType.Integer)
                throw new ArgumentException("Transfer " + i + " count must be an integer.");
            try
            {
                ReadShipment(manager, transfer);
            }
            catch (ArgumentException error)
            {
                throw new ArgumentException("Transfer " + i + ": " + error.Message);
            }
            transfers[i] = transfer;
        }
        shippingBatch = new ShippingBatch {
            Id = id, Manager = manager, Scene = SceneManager.GetActiveScene().handle,
            LastFrame = Time.frameCount, Transfers = transfers
        };
    }

    private static void AdvanceShippingBatch(PlayerInputManager manager)
    {
        var batch = shippingBatch;
        if (batch.LastFrame == Time.frameCount)
            return;
        batch.LastFrame = Time.frameCount;
        if (manager != batch.Manager || SceneManager.GetActiveScene().handle != batch.Scene)
        {
            StopShippingBatch("The active campaign changed.");
            return;
        }

        int index = batch.Receipts.Count;
        var result = JObject.FromObject(DispatchShipment(manager, batch.Transfers[index]));
        batch.Receipts.Add(new { index, result, error = (string)null });
        bool stopped = (int)result["heldAfter"] != 0 || (int)result["onGround"] != 0;
        if (stopped || batch.Receipts.Count == batch.Transfers.Length)
            FinishShippingBatch(stopped);
    }

    private static void StopShippingBatch(string error)
    {
        var receipts = shippingBatch.Receipts;
        receipts.Add(new { index = receipts.Count, result = (object)null, error });
        FinishShippingBatch(true);
    }

    private static void FinishShippingBatch(bool stopped)
    {
        var batch = shippingBatch;
        shippingBatch = null;
        cursor = null;
        Reply(batch.Id, new { action = "shipbatch", receipts = batch.Receipts.ToArray(), stopped });
    }

    private static void Start(PlayerInputManager manager, JObject request, string id, string action)
    {
        string input = action == "click" ? "PlayerClick" : action == "collect" ? "Collect" : "Drop";
        EnsureAction(manager, input);
        var point = TargetPoint(manager, request);
        ObservePoint(point);
        var screen = Camera.main.WorldToScreenPoint(point);
        var collect = manager.playerCollect;
        var newOperation = new Operation {
            Id = id, Action = action, Input = input, Manager = manager, Point = point,
            Before = collect.GetHeldResources().Count
        };
        if (action == "click")
        {
            newOperation.Remaining = request["count"] == null ? 1 : (int)Number(request, "count", 1, 160);
            RequireClickTarget(manager, point);
        }
        else
        {
            float seconds = request["seconds"] == null ? 0.5f : Number(request, "seconds", 0.1f, 6);
            newOperation.EndsAt = Time.timeAsDouble + seconds;
            int count = request["count"] == null ? collect.maxHandSize : (int)Number(request, "count", 1, 160);
            newOperation.HandTarget = action == "collect"
                ? Math.Min(collect.maxHandSize, newOperation.Before + count)
                : Math.Max(0, newOperation.Before - count);
            string filter = (string)request["resource"];
            if (action == "collect" && filter != null)
            {
                var resource = ParseResource(filter);
                var collider = Physics2D.OverlapPoint(point, collect.storageLayerMask);
                var chest = collider ? collider.GetComponent<StorageBuilding>() : null;
                if (chest && chest.storedResourceType != resource)
                    throw new ArgumentException("That chest contains a different resource.");
                newOperation.Resource = resource;
            }
        }
        operation = newOperation;
        if (action == "collect" && newOperation.Before < newOperation.HandTarget)
        {
            cursor = screen;
            Collect(collect, true);
        }
        else if (action == "drop" && newOperation.Before > newOperation.HandTarget)
        {
            cursor = screen;
            Drop(collect, true);
        }
        else if (action != "click")
            Finish();
    }

    private static void StartBuild(PlayerInputManager manager, JObject request, string id)
    {
        EnsureAction(manager, null);
        Vector2 point = TargetPoint(manager, request);
        ObservePoint(point);
        string type = (string)request["building"];
        var blueprint = PlayerBuildingManager.Instance.GetPlayerBlueprints().SingleOrDefault(candidate =>
            candidate.blueprintSO && candidate.blueprintSO.buildablePrefab &&
            string.Equals(candidate.blueprintSO.buildablePrefab.buildingType.ToString(), type, StringComparison.OrdinalIgnoreCase));
        if (blueprint == null || !blueprint.unlocked || !blueprint.recipeBought)
            throw new InvalidOperationException("Unlock and purchase the blueprint before placing it.");

        StartBuilding(manager.playerBuild, blueprint.blueprintSO);
        operation = new Operation {
            Id = id, Action = "build", Input = "PlayerClick", Manager = manager, Point = point,
            Blueprint = (BuildingBlueprint)Placement.GetValue(manager.playerBuild), StartFrame = Time.frameCount,
            FixedStart = Time.fixedTimeAsDouble, EndsAt = Time.realtimeSinceStartupAsDouble + 3
        };
        cursor = Camera.main.WorldToScreenPoint(point);
    }

    private static void AdvanceBuild(Operation current)
    {
        var blueprint = current.Blueprint;
        if (!blueprint)
            throw new InvalidOperationException("Blueprint placement was canceled.");

        if (!blueprint.IsPlaced())
        {
            EnsureAction(current.Manager, current.Input, PlayerInputState.build);
            if (Time.realtimeSinceStartupAsDouble > current.EndsAt)
                throw new InvalidOperationException("Timed out waiting for the placement collision check.");

            cursor = Camera.main.WorldToScreenPoint(current.Point);
            if (Time.frameCount < current.StartFrame + 2 || Time.fixedTimeAsDouble < current.FixedStart + 0.06)
                return;

            PlaceBuilding(current.Manager.playerBuild);
            if (!blueprint.IsPlaced())
                throw new InvalidOperationException("The game blocked placement at this location.");
        }

        operation = null;
        cursor = null;
        Reply(current.Id, new { id = blueprint.GetInstanceID(), storageId = blueprint.resourceStorage.GetInstanceID(),
            building = blueprint.blueprintSO.buildablePrefab.buildingType.ToString(), point = Aim(blueprint.resourceStorage) });
    }

    private static void RequireClickTarget(PlayerInputManager manager, Vector2 point)
    {
        var collider = Physics2D.OverlapPoint(point, (int)ClickLayer.GetValue(manager.playerClick));
        if (!collider || !collider.GetComponent<RessourceNode>())
            throw new ArgumentException("Aim at a resource node.");
    }

    private static void Advance(PlayerInputManager manager)
    {
        var current = operation;
        if (current.Manager != manager)
        {
            Finish("The active campaign changed.");
            return;
        }
        if (current.Action == "build")
        {
            AdvanceBuild(current);
            return;
        }
        EnsureAction(manager, current.Input);
        var collect = manager.playerCollect;
        var time = Time.timeAsDouble;
        if (current.Action == "click")
        {
            if (time < current.NextClick)
                return;
            RequireClickTarget(manager, current.Point);
            cursor = Camera.main.WorldToScreenPoint(current.Point);
            try { Click(manager.playerClick, false); }
            finally { cursor = null; }
            current.Clicks++;
            current.Remaining--;
            current.NextClick = time + Mathf.Clamp(manager.autoClickInterval, 0.06f, 0.2f);
            if (current.Remaining == 0)
                Finish();
            return;
        }

        int held = collect.GetHeldResources().Count;
        if (time >= current.EndsAt || (current.Action == "collect" ? held >= current.HandTarget : held <= current.HandTarget))
            Finish();
        else
            cursor = Camera.main.WorldToScreenPoint(current.Point);
    }

    private static void Finish(string error = null)
    {
        var current = operation;
        operation = null;
        cursor = null;
        if (current.Action == "build" && current.Manager && current.Blueprint &&
            (BuildingBlueprint)Placement.GetValue(current.Manager.playerBuild) == current.Blueprint)
            current.Manager.CancelBuildingPlacement();
        var collect = current.Manager ? current.Manager.playerCollect : null;
        if (collect)
        {
            if (current.Action == "collect") Collect(collect, false);
            if (current.Action == "drop") Drop(collect, false);
        }
        Reply(current.Id, new {
            action = current.Action, clicks = current.Clicks, heldBefore = current.Before,
            heldAfter = collect ? collect.GetHeldResources().Count : current.Before
        }, error);
    }

    private static void Reply(string id, object result, string error = null)
    {
        pendingReply = new { id, ok = error == null, error, result };
    }

    private static object Status(PlayerInputManager manager)
    {
        bool ready = Ready(manager);
        return new {
            ready, paused = Paused(), speed, timeScale = Time.timeScale, gameTime = Time.timeAsDouble,
            unscaledTime = Time.unscaledTimeAsDouble, clickLevel = manager.playerClick.clickLevel,
            clickPower = manager.playerClick.clickPower, handCapacity = manager.playerCollect.maxHandSize,
            camera = Camera.main ? Aim(Camera.main) : null, typedCollection = true, maxClicks = 160,
            bulkTransfer = true, bulkTransferBatch = true,
            watch, vsync = QualitySettings.vSyncCount, maxFps = Application.targetFrameRate,
            held = ready ? manager.playerCollect.GetHeldResources()
                .GroupBy(go => go.GetComponent<Resource>().resourceType)
                .Select(group => new { type = group.Key.ToString(), count = group.Count() }).ToArray() : null
        };
    }

    private static T[] Find<T>() where T : Object
    {
        return Object.FindObjectsByType<T>(FindObjectsSortMode.InstanceID);
    }

    private static object Scan(string kind)
    {
        if (kind == "resources" || kind == "all")
        {
            if (kind == "resources") return new { resources = Resources() };
            return new { resources = Resources(), nodes = Nodes(), buildings = Buildings() };
        }
        if (kind == "nodes") return new { nodes = Nodes() };
        if (kind == "buildings") return new { buildings = Buildings() };
        throw new ArgumentException("Unknown scan kind.");
    }

    private static object Resources()
    {
        return SpawnedResourceManager.Instance.spawnedResources
            .Where(r => r && r.gameObject.activeInHierarchy && !r.toBeDestroyed)
            .Select(r => new { type = r.resourceType.ToString(), id = r.GetInstanceID(),
                x = r.transform.position.x, y = r.transform.position.y, collectible = IsCollectible(r) })
            .ToArray();
    }

    private static object Nodes()
    {
        return Find<RessourceNode>().Select(n => new {
            type = n.resourceType.ToString(), id = n.GetInstanceID(), point = Aim(n),
            n.clickable, n.clickLevelNeeded, n.clicksNeededForResource
        }).ToArray();
    }

    private static object Buildings()
    {
        return new {
            storages = Find<ResourceStorage>().Where(s => (bool)StorageActive.GetValue(s)).Select(s => new {
                id = s.GetInstanceID(), name = s.name, point = Aim(s),
                stored = Stored(s).Select(v => new {
                    type = v.resourceType.ToString(), count = v.storedAmount, limit = v.storageLimit
                }).ToArray()
            }).ToArray(),
            chests = Find<StorageBuilding>().Select(s => new {
                id = s.GetInstanceID(), name = s.name, point = Aim(s),
                type = s.storedResourceType.ToString(), count = s.storedAmount
            }).ToArray(),
            processors = Find<ResourceProcessor>().Select(p => {
                var recipe = p.GetSelectedRecipe();
                var fuel = p.fuelStorage;
                return new {
                    id = p.GetInstanceID(), name = p.name, point = Aim(p),
                    inputStorage = p.resourceStorage ? p.resourceStorage.GetInstanceID() : 0,
                    fuelPoint = fuel ? Aim(fuel) : null,
                    fuel = fuel ? fuel.fuelList.Sum(f => f.fuelLeft) : 0,
                    fuelLimit = fuel ? fuel.maxStorage : 0,
                    fuelSlots = fuel ? fuel.fuelList.Count : 0,
                    output = recipe ? recipe.resourceToGet.ToString() : null,
                    ingredients = recipe ? recipe.neededResources.Select(r => new {
                        type = r.resourceType.ToString(), count = r.amountNeeded
                    }).ToArray() : null,
                    processing = p.GetProcessing(), remaining = p.GetProcessingTimeLeft()
                };
            }).ToArray(),
            portals = Find<Portal>().Select(p => new {
                id = p.GetInstanceID(), stage = p.builtStage, finished = p.IsFinished(),
                storage = p.resourceStorage ? p.resourceStorage.GetInstanceID() : 0
            }).ToArray(),
            blueprints = Find<BuildingBlueprint>().Where(b => b.IsPlaced()).Select(b => new {
                id = b.GetInstanceID(), type = b.blueprintSO.buildablePrefab.buildingType.ToString(),
                storage = b.resourceStorage.GetInstanceID(), point = Aim(b.resourceStorage)
            }).ToArray()
        };
    }

    private static object Aim(Component component)
    {
        var collider = component.GetComponent<Collider2D>();
        var position = collider ? collider.bounds.center : component.transform.position;
        return new { x = position.x, y = position.y };
    }
}
