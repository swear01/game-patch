using System;
using System.IO;
using UndertaleModLib.Compiler;
using UndertaleModLib.Decompiler;
using UndertaleModLib.Models;
using UndertaleModLib.Util;

EnsureDataLoaded();

const string drawEntryName = "gml_Object_objCTRLgame_Draw_75";
var drawEntry = Data.Code.ByName(drawEntryName);
if (drawEntry == null)
    throw new InvalidOperationException("Expected Max Manos Draw GUI End event was not found.");

var context = new GlobalDecompileContext(Data);
string draw = new Underanalyzer.Decompiler.DecompileContext(
    context, drawEntry, Data.ToolInfo.DecompilerSettings).DecompileToString();

int aimStart = draw.IndexOf("            if (global.runPhase == \"preShot\")", StringComparison.Ordinal);
if (aimStart < 0)
    throw new InvalidOperationException("Expected aiming block start was not found.");
int aimEnd = draw.IndexOf("                draw_sprite_ext(sprMANOSfingerGun", aimStart, StringComparison.Ordinal);
if (aimEnd < 0)
    throw new InvalidOperationException("Expected aiming block end was not found.");

string aim = draw.Substring(aimStart, aimEnd - aimStart);
string replacement = "            if (global.runPhase == \"action\")\n            {\n";
draw = draw.Remove(aimStart, aimEnd - aimStart).Insert(aimStart, replacement);

string endStep = "if (room == rmArena && !global.pause && global.arrayModifiers[global.gameModifier] == \"FingerGun\")\n{\n"
    + aim + "\n}\n}\n";
endStep += File.ReadAllText(Path.Combine("work", "draw_end_step.gml"));

var group = new CodeImportGroup(Data);
group.QueueAppend("gml_Object_objCTRLgame_Create_0",
    "global.__codexDrawStride = 1; global.__codexTotalSteps = 0; global.__codexDrawFrames = 0;");
group.QueueAppend(Data.GameObjects.ByName("objCTRLgame").EventHandlerFor(EventType.Step, 2u, Data), endStep);
group.QueueReplace(drawEntryName, draw);
group.Import();
Console.WriteLine("Moved the aim update to End Step. F6 cycles 1/5/10; F7 records a sample.");
