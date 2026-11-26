using System.Security.Cryptography;
using Mono.Cecil;
using Mono.Cecil.Cil;

const string OriginalHash = "157EC56C8FB6E3A1C93BB58DADA8D81A39F7ED162CADE5F7A7586E08EACCDB84";
const string GameAssembly = "Assembly-CSharp.dll";
const string AssistAssembly = "CypherAssist.dll";

try
{
    if (args.Length < 2 || args.Length > 3)
        throw new ArgumentException("Usage: PatchCypher <install|restore> <managed-directory> [assist-assembly]");

    string gamePath = Path.Combine(args[1], GameAssembly);
    string assistPath = Path.Combine(args[1], AssistAssembly);
    string backupPath = gamePath + ".cypher-assist-original";

    switch (args[0])
    {
        case "install" when args.Length == 3:
            if (HasAssistReference(gamePath))
            {
                if (Hash(backupPath) != OriginalHash || Hash(assistPath) != Hash(args[2]))
                    throw new InvalidOperationException("Existing installation differs. Restore the original before reinstalling.");
                Console.WriteLine("Cypher Assist is already installed.");
                break;
            }

            string stagedPath = gamePath + ".cypher-assist-" + Guid.NewGuid().ToString("N");
            bool addedAssist = false;
            try
            {
                Patch(gamePath, args[2], stagedPath);
                if (!File.Exists(assistPath))
                {
                    File.Copy(args[2], assistPath);
                    addedAssist = true;
                }
                else if (Hash(assistPath) != Hash(args[2]))
                {
                    throw new InvalidOperationException("A different CypherAssist.dll already exists.");
                }

                File.Replace(stagedPath, gamePath, backupPath);
            }
            catch
            {
                if (addedAssist && Hash(gamePath) == OriginalHash)
                    File.Delete(assistPath);
                throw;
            }
            finally
            {
                File.Delete(stagedPath);
            }

            Console.WriteLine("Installed Cypher Assist for the next game launch. Original backed up to " + backupPath);
            break;
        case "restore" when args.Length == 2:
            if (Hash(gamePath) == OriginalHash)
            {
                Console.WriteLine("Cypher already has the original game assembly.");
                break;
            }

            if (!HasAssistReference(gamePath) || Hash(backupPath) != OriginalHash)
                throw new InvalidOperationException("The current game assembly or its backup is unexpected.");

            File.Replace(backupPath, gamePath, null);
            File.Delete(assistPath);
            Console.WriteLine("Restored the original game assembly.");
            break;
        default:
            throw new ArgumentException("Invalid patch command.");
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

static bool HasAssistReference(string path)
{
    using var game = AssemblyDefinition.ReadAssembly(path);
    return game.MainModule.AssemblyReferences.Any(reference => reference.Name == "CypherAssist");
}

static void Patch(string gamePath, string assistPath, string stagedPath)
{
    if (Hash(gamePath) != OriginalHash)
        throw new InvalidOperationException("This Cypher build is unsupported. The original assembly was left in place.");

    using var resolver = new DefaultAssemblyResolver();
    resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(gamePath))!);
    resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(assistPath))!);
    var reader = new ReaderParameters { InMemory = true, AssemblyResolver = resolver };
    using var game = AssemblyDefinition.ReadAssembly(gamePath, reader);
    using var assist = AssemblyDefinition.ReadAssembly(assistPath, reader);
    var module = game.MainModule;
    var helper = assist.MainModule.GetType("CypherAssist");
    var menus = module.GetType("Menus");
    var menuStart = menus.Methods.Single(method => method.Name == "Start");
    var startIL = menuStart.Body.GetILProcessor();
    startIL.InsertBefore(menuStart.Body.Instructions[0], startIL.Create(OpCodes.Call, ImportHelper("Initialize")));

    var menuUpdate = menus.Methods.Single(method => method.Name == "Update");
    var menuIL = menuUpdate.Body.GetILProcessor();
    var first = menuUpdate.Body.Instructions[0];
    menuIL.InsertBefore(first, menuIL.Create(OpCodes.Ldarg_0));
    menuIL.InsertBefore(first, menuIL.Create(OpCodes.Call, ImportHelper("Tick")));

    var answerInput = module.GetType("Screen").Methods.Single(method => method.Name == "TextInputUpdate");
    var keyChecks = FindInputCalls("GetKeyDown").ToArray();
    var heldChecks = FindInputCalls("GetKey").ToArray();
    var inputStringCalls = FindInputCalls("get_inputString").ToArray();
    if (keyChecks.Length != 4 || heldChecks.Length != 2 || inputStringCalls.Length != 4)
        throw new InvalidOperationException("Cypher answer input does not match the expected build.");

    ReplaceCalls(keyChecks, "KeyPressed");
    ReplaceCalls(heldChecks, "KeyHeld");
    ReplaceCalls(inputStringCalls, "InputText");

    game.Write(stagedPath);
    if (!HasAssistReference(stagedPath))
        throw new InvalidOperationException("The staged patch could not be verified.");

    MethodReference ImportHelper(string name) =>
        module.ImportReference(helper.Methods.Single(method => method.Name == name));

    void ReplaceCalls(IEnumerable<Instruction> calls, string name)
    {
        var replacement = ImportHelper(name);
        foreach (var call in calls)
            call.Operand = replacement;
    }

    IEnumerable<Instruction> FindInputCalls(string name) =>
        answerInput.Body.Instructions.Where(instruction => instruction.OpCode == OpCodes.Call &&
            instruction.Operand is MethodReference method &&
            method.DeclaringType.FullName == "UnityEngine.Input" && method.Name == name);
}
