using System.Security.Cryptography;
using System.Text;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

const string OriginalHash = "F44D8FD3A0BEF0524B73BF40CB14F3EBA02A0252836EBA27D628B2AC41EEDBFD";
const string PreviousPatchHash = "245FAE1328364BA2BB413FBC9782C279A8D93B7F448D1BA9831D602A69A1449C";
const string HelperName = "ClickMageControl";
var helperVersion = new Version(0, 0, 0, 0);

try
{
    bool installing = args is ["install", _, _];
    if (!installing && args is not ["restore", _])
        throw new ArgumentException("Usage: PatchClickMage install <managed-directory> <control-assembly> | restore <managed-directory>");

    string managedPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[1]));
    string gamePath = Path.Combine(managedPath, "_GameAssembly.dll");
    string helperPath = Path.Combine(managedPath, HelperName + ".dll");
    string backupPath = gamePath + ".clickmage-control-original";
    string lockId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(managedPath.ToUpperInvariant())));
    using var installLock = new Mutex(false, "ClickMageControl-" + lockId);
    try
    {
        if (!installLock.WaitOne(0))
            throw new InvalidOperationException("Another Click Mage installation or restoration is running.");
    }
    catch (AbandonedMutexException)
    {
        // The previous installer stopped. Verify the files before continuing.
    }

    try
    {
        string currentHash = Hash(gamePath);
        bool isOriginal = currentHash == OriginalHash;
        bool hasBackup = File.Exists(backupPath);
        if ((hasBackup && Hash(backupPath) != OriginalHash) || (!isOriginal && !hasBackup))
            throw new InvalidOperationException("The Click Mage assembly or its original backup is unsupported.");

        string stage = Path.Combine(managedPath, ".clickmage-control-" + Guid.NewGuid().ToString("N"));
        string stagedGame = stage + "-game";
        string stagedHelper = stage + "-helper";
        string previousHelper = stage + "-previous";
        bool keepPreviousHelper = false;
        try
        {
            if (!isOriginal || installing)
                WritePatch(hasBackup ? backupPath : gamePath, stagedGame);

            string patchedHash = isOriginal && !installing ? OriginalHash : Hash(stagedGame);
            if (!isOriginal && currentHash != patchedHash && currentHash != PreviousPatchHash)
                throw new InvalidOperationException("The installed assembly does not match this Click Mage patch.");

            bool hasHelper = File.Exists(helperPath);
            if (hasHelper && (hasBackup || installing))
            {
                if (!hasBackup)
                    throw new InvalidOperationException("An unrelated ClickMageControl.dll already exists.");
                VerifyHelper(helperPath);
            }

            if (installing)
            {
                VerifyHelper(args[2], requireCurrent: true);
                if (!hasBackup)
                {
                    File.Copy(gamePath, previousHelper);
                    if (Hash(previousHelper) != OriginalHash)
                        throw new InvalidOperationException("The game assembly changed during installation.");
                    File.Move(previousHelper, backupPath);
                }

                bool changeHelper = !hasHelper || Hash(helperPath) != Hash(args[2]);
                if (changeHelper)
                {
                    File.Copy(args[2], stagedHelper);
                    if (hasHelper)
                        File.Replace(stagedHelper, helperPath, previousHelper);
                    else
                        File.Move(stagedHelper, helperPath);
                }

                try
                {
                    if (Hash(gamePath) != currentHash)
                        throw new InvalidOperationException("The game assembly changed during installation.");
                    if (currentHash != patchedHash)
                        File.Replace(stagedGame, gamePath, null);
                }
                catch
                {
                    if (changeHelper)
                    {
                        if (hasHelper)
                        {
                            keepPreviousHelper = true;
                            try
                            {
                                File.Replace(previousHelper, helperPath, null);
                                keepPreviousHelper = false;
                            }
                            catch (Exception rollbackError)
                            {
                                throw new IOException("The previous control DLL could not be restored. Backup: " + previousHelper,
                                    rollbackError);
                            }
                        }
                        else
                            File.Delete(helperPath);
                    }
                    throw;
                }

                Console.WriteLine("Click Mage control is installed. Original assembly backup: " + backupPath);
            }
            else
            {
                if (!isOriginal)
                {
                    File.Copy(backupPath, stagedHelper);
                    if (Hash(stagedHelper) != OriginalHash || Hash(gamePath) != currentHash)
                        throw new InvalidOperationException("The game assembly or its backup changed during restoration.");
                    File.Replace(stagedHelper, gamePath, null);
                }

                if (hasBackup && hasHelper)
                    File.Delete(helperPath);
                Console.WriteLine("Click Mage has the original game assembly.");
            }
        }
        finally
        {
            File.Delete(stagedGame);
            File.Delete(stagedHelper);
            if (!keepPreviousHelper)
                File.Delete(previousHelper);
        }
    }
    finally
    {
        installLock.ReleaseMutex();
    }

    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine(error.Message);
    return 1;
}

static string Hash(string path)
{
    using var stream = File.OpenRead(path);
    return Convert.ToHexString(SHA256.HashData(stream));
}

void VerifyHelper(string path, bool requireCurrent = false)
{
    using var assembly = AssemblyDefinition.ReadAssembly(path);
    if (assembly.Name.Name != HelperName || assembly.Name.Version != helperVersion || assembly.Name.HasPublicKey)
        throw new InvalidOperationException("Unexpected Click Mage control assembly identity.");

    var type = assembly.MainModule.GetType(HelperName);
    if (type is null || !type.IsPublic || !type.IsAbstract || !type.IsSealed)
        throw new InvalidOperationException("The Click Mage control assembly is missing its entry point.");

    Require("Tick", "System.Void", "PlayerInputManager");
    Require("ResolveCursor", "UnityEngine.Vector2", "PlayerCursorManager");
    Require("HasCollectionCapacity", "System.Boolean", "PlayerCollect");
    if (requireCurrent)
    {
        Require("FilterCollectionCandidates", "UnityEngine.Collider2D[]", "UnityEngine.Collider2D[]");
        Require("TickMenu", "System.Void", "MainMenu");
    }

    void Require(string name, string returnType, string parameterType)
    {
        if (!type.Methods.Any(method => method.Name == name && method.IsPublic && method.IsStatic &&
            !method.HasGenericParameters && method.ReturnType.FullName == returnType &&
            method.Parameters.Count == 1 && method.Parameters[0].ParameterType.FullName == parameterType))
            throw new InvalidOperationException("The Click Mage control assembly is missing " + name + ".");
    }
}

void WritePatch(string originalPath, string stagedPath)
{
    using var game = AssemblyDefinition.ReadAssembly(originalPath, new ReaderParameters { InMemory = true });
    var module = game.MainModule;
    var helperAssembly = new AssemblyNameReference(HelperName, helperVersion);
    module.AssemblyReferences.Add(helperAssembly);
    var helper = new TypeReference("", HelperName, module, helperAssembly);

    var inputManager = module.GetType("PlayerInputManager");
    var cursorManager = module.GetType("PlayerCursorManager");
    var playerClick = module.GetType("PlayerClick");
    var playerCollect = module.GetType("PlayerCollect");
    var cursorMethod = GetMethod(cursorManager, "GetCursorPosition");
    var tick = Reference("Tick", module.TypeSystem.Void, inputManager);
    var resolveCursor = Reference("ResolveCursor", cursorMethod.ReturnType, cursorManager);
    var hasCapacity = Reference("HasCollectionCapacity", module.TypeSystem.Boolean, playerCollect);

    var update = GetMethod(inputManager, "Update");
    var first = update.Body.Instructions[0];
    var inputIL = update.Body.GetILProcessor();
    inputIL.InsertBefore(first, inputIL.Create(OpCodes.Ldarg_0));
    inputIL.InsertBefore(first, inputIL.Create(OpCodes.Call, tick));

    var mainMenu = module.GetType("MainMenu");
    if (mainMenu.Methods.Any(method => method.Name == "Update"))
        throw new InvalidOperationException("Click Mage main menu does not match the supported build.");
    var menuUpdate = new MethodDefinition("Update", MethodAttributes.Private | MethodAttributes.HideBySig, module.TypeSystem.Void);
    mainMenu.Methods.Add(menuUpdate);
    var menuIL = menuUpdate.Body.GetILProcessor();
    menuIL.Emit(OpCodes.Ldarg_0);
    menuIL.Emit(OpCodes.Call, Reference("TickMenu", module.TypeSystem.Void, mainMenu));
    menuIL.Emit(OpCodes.Ret);

    ReplaceCursorCalls(playerClick, "Click", 1);
    ReplaceCursorCalls(playerCollect, "IsDroppableLocation", 2);
    ReplaceCursorCalls(playerCollect, "DropResources", 1);
    ReplaceCursorCalls(playerCollect, "TriggerStorageCheckUnderPointer", 1);
    ReplaceCursorCalls(playerCollect, "StartStopCollecting", 1);
    ReplaceCursorCalls(playerCollect, "CollectResources", 1);
    ReplaceCursorCalls(playerCollect, "CollectResourcesFromStorage", 1);
    ReplaceCursorCalls(module.GetType("BuildingBlueprint"), "LateUpdate", 1);

    var collect = GetMethod(playerCollect, "CollectResources");
    collect.Body.SimplifyMacros();
    var overlap = collect.Body.Instructions.Single(instruction =>
        instruction.Operand is MethodReference method && method.DeclaringType.FullName == "UnityEngine.Physics2D" &&
        method.Name == "OverlapCircleAll");
    var colliderArray = ((MethodReference)overlap.Operand).ReturnType;
    var moveResource = collect.Body.Instructions.Single(instruction =>
        instruction.Operand is MethodReference method && method.Name == "get_Instance" &&
        method.DeclaringType is GenericInstanceType generic && generic.GenericArguments.Count == 1 &&
        generic.GenericArguments[0].FullName == "SpawnedResourceManager");
    var exit = collect.Body.Instructions[^1];
    if (exit.OpCode != OpCodes.Ret || moveResource.Previous?.OpCode != OpCodes.Brfalse)
        throw new InvalidOperationException("Click Mage resource collection does not match the supported build.");

    var collectIL = collect.Body.GetILProcessor();
    collectIL.InsertAfter(overlap, collectIL.Create(OpCodes.Call,
        Reference("FilterCollectionCandidates", colliderArray, colliderArray)));
    collectIL.InsertBefore(moveResource, collectIL.Create(OpCodes.Ldarg_0));
    collectIL.InsertBefore(moveResource, collectIL.Create(OpCodes.Call, hasCapacity));
    collectIL.InsertBefore(moveResource, collectIL.Create(OpCodes.Brfalse, exit));
    collect.Body.OptimizeMacros();

    game.Write(stagedPath, new WriterParameters { DeterministicMvid = true, Timestamp = 0 });

    MethodReference Reference(string name, TypeReference result, TypeReference parameter)
    {
        var reference = new MethodReference(name, result, helper);
        reference.Parameters.Add(new ParameterDefinition(parameter));
        return reference;
    }

    void ReplaceCursorCalls(TypeDefinition type, string methodName, int count)
    {
        var calls = GetMethod(type, methodName).Body.Instructions.Where(instruction =>
            instruction.OpCode == OpCodes.Callvirt && instruction.Operand is MethodReference method &&
            method.FullName == cursorMethod.FullName).ToArray();
        if (calls.Length != count)
            throw new InvalidOperationException($"Unexpected cursor calls in {type.Name}.{methodName}.");

        foreach (var call in calls)
        {
            call.OpCode = OpCodes.Call;
            call.Operand = resolveCursor;
        }
    }
}

static MethodDefinition GetMethod(TypeDefinition type, string name) =>
    type.Methods.Single(method => method.Name == name && method.HasBody);
