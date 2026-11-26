using System;
using System.IO;
using System.Linq;
using UndertaleModLib.Decompiler;

EnsureDataLoaded();
var folder = Path.GetFullPath("work/draw-patched-audit");
Directory.CreateDirectory(folder);
var context = new GlobalDecompileContext(Data);
File.WriteAllLines(Path.Combine(folder, "code-names.txt"), Data.Code.Select(c => c.Name.Content));
foreach (var code in Data.Code.Where(c => c.ParentEntry == null &&
    (c.Name.Content.StartsWith("gml_GlobalScript_") || c.Name.Content.Contains("_Draw_") || c.Name.Content.Contains("objCTRLgame") ||
     c.Name.Content.Contains("objCTRLcore") || c.Name.Content.Contains("numbersDisplay"))))
{
    var source = new Underanalyzer.Decompiler.DecompileContext(context, code, Data.ToolInfo.DecompilerSettings).DecompileToString();
    File.WriteAllText(Path.Combine(folder, code.Name.Content + ".gml"), source);
}
Console.WriteLine("AUDIT_EXPORTED " + Directory.GetFiles(folder).Length);
