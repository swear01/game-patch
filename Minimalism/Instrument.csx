using System;
using System.Linq;
using System.Text.RegularExpressions;
using UndertaleModLib.Compiler;
using UndertaleModLib.Models;

var import = new CodeImportGroup(Data);
var controller = Data.GameObjects.ByName("obj_control");
var rate = int.Parse(Environment.GetEnvironmentVariable("MINIMALISM_TEST_RATE") ?? "60");
if (rate != 60 && rate != 300)
    throw new InvalidOperationException("Expected a test rate of 60 or 300 FPS.");
var saveFolder = Environment.GetEnvironmentVariable("MINIMALISM_TEST_FOLDER") ?? "MinimalismPlaytest";
if (!Regex.IsMatch(saveFolder, "^MinimalismPlaytest(?:_[a-f0-9]{12})?$"))
    throw new InvalidOperationException("Invalid playtest save folder name.");
var startLevel = int.Parse(Environment.GetEnvironmentVariable("MINIMALISM_TEST_START") ?? "1");
if (startLevel < 1 || startLevel > 31)
    throw new InvalidOperationException("Invalid starting room.");
var slot = int.Parse(Environment.GetEnvironmentVariable("MINIMALISM_TEST_SLOT") ?? "0");
if (slot < 0 || slot > 4)
    throw new InvalidOperationException("Invalid playtest window slot.");
var title = slot == 0 ? "Minimalism Playtest" : "Minimalism Playtest " + slot;
var collectSymbols = Environment.GetEnvironmentVariable("MINIMALISM_TEST_SYMBOLS") != "0";
var steamAchievements = Environment.GetEnvironmentVariable("MINIMALISM_TEST_STEAM") == "1";
var yieldWhileWaiting = Environment.GetEnvironmentVariable("MINIMALISM_TEST_WAIT_DLL") == "1";
if (steamAchievements && slot > 1)
    throw new InvalidOperationException("Only the primary playtest may write Steam achievements.");
var tileWindow = slot == 0 ? "" : "if (bot_frame == 0) { var tx = " + ((slot - 1) % 2) +
    " * floor(display_get_width() / 2); var ty = " + ((slot - 1) / 2) +
    " * floor(display_get_height() / 2); if (window_get_x() != tx || window_get_y() != ty) { window_set_position(tx, ty); } }";

Data.GeneralInfo.FileName = Data.Strings.MakeString(saveFolder);
Data.GeneralInfo.Name = Data.Strings.MakeString(saveFolder);
Data.GeneralInfo.DisplayName = Data.Strings.MakeString("Minimalism Playtest");
Data.Options.Info &= ~UndertaleOptions.OptionsFlags.Freeze;
foreach (var room in Data.Rooms.Where(r => Regex.IsMatch(r.Name.Content, "^rm_level_[0-9]{2}$")))
    room.Speed = (uint)rate;

foreach (var code in Data.Code.Where(c => c.Name.Content.StartsWith("gml_Script_") && Regex.IsMatch(c.Name.Content, "_(state_normal|state_walljump|wallstick)$")))
{
    import.QueueRegexFindReplace(code, "gamepad_axis_value\\(global\\.gamepad_id, gp_axislh\\)", "0");
    import.QueueRegexFindReplace(code, "gamepad_button_check(?:_released)?\\(global\\.gamepad_id, gp_face1\\)", "false");
    import.QueueFindReplace(code, "keyboard_check(vk_left)", "((global.bot_action & 1) != 0)");
    import.QueueFindReplace(code, "keyboard_check(vk_right)", "((global.bot_action & 2) != 0)");
    import.QueueFindReplace(code, "keyboard_check(vk_space)", "((global.bot_action & 4) != 0)");
    import.QueueFindReplace(code, "keyboard_check_released(vk_space)", "((global.bot_prev & 4) != 0 && (global.bot_action & 4) == 0)");
    import.QueueRegexFindReplace(code, "keyboard_check\\(ord\\(\"[AD]\"\\)\\)", "false");
}

var step = Data.Code.ByName("gml_Object_obj_control_Step_0");
import.QueueFindReplace(step, "if (keyboard_check(vk_space) || gamepad_jump)", "if ((global.bot_action & 4) != 0)");
import.QueueFindReplace(step, "var key__pause = keyboard_check_released(vk_escape);", "var key__pause = false;");
import.QueueRegexFindReplace(step, @"var gamepad_pause = [^;]+;", "var gamepad_pause = false;");
foreach (var name in new[] { "obj_control", "obj_control_menu" })
{
    var code = Data.Code.ByName("gml_Object_" + name + "_Create_0");
    var width = slot == 0 ? "960" : "floor(display_get_width() / 2) - 8";
    var height = slot == 0 ? "540" : "floor(display_get_height() / 2) - 32";
    import.QueueFindReplace(code, "display_get_width()", width);
    import.QueueFindReplace(code, "display_get_height()", height);
    if (name == "obj_control_menu")
        import.QueueAppend(code, "\nwindow_set_fullscreen(false); display_reset(0, false); window_set_caption(\"" + title + "\");");
    else
        import.QueueFindReplace(code, "window_set_size(global.displayWidth, global.displayHeight);", ";");
}

import.QueueAppend(Data.Code.ByName("gml_Object_obj_gui_game_Draw_64"),
    "\ndraw_set_color(c_white); draw_text_border(12, global.displayHeight - 42, c_white, c_black, \"" +
    (slot == 0 ? "" : slot + "  /  ") + "LEVEL \" + string(global.level) + \"  /  " + (rate / 60) +
    "x\"" + (collectSymbols
        ? " + \"  /  SYMBOLS \" + string(global.bot_symbol_total - instance_number(obj_bonus_eng) - instance_number(obj_bonus_jp)) + \"/\" + string(global.bot_symbol_total)"
        : "") + " + (global.bot_waiting ? \"  /  PLANNING\" : \"\"));");

// Every lane keeps its own save. Only the opted-in main lane uses native Steam awards.
foreach (var name in new[] { "loadLevel", "saveLevel", "loadMusic", "saveMusic" })
    import.QueueFindReplace(Data.Code.ByName("gml_Script_" + name), "\"save.ini\"", "\"minimalism-playtest-save.ini\"");
if (!steamAchievements)
{
    foreach (var name in new[] { "gml_Room_rm_g_menu_Create", "gml_Room_rm_level_01_Create", "gml_Script_checkTakedAllSymb", "gml_Script_giveAchivementLevel", "gml_Object_obj_bonus_eng_Collision_21", "gml_Object_obj_bonus_jp_Collision_21" })
        import.QueueRegexFindReplace(Data.Code.ByName(name), @"steam_set_achievement\([^;]*\);", ";");
}
else
{
    import.QueuePrepend(Data.Code.ByName("gml_Object_obj_door_Alarm_0"), @"
global.bot_previous_achievement = steam_get_achievement(""LEVEL"" + string(global.level));
");
}
if (collectSymbols)
{
    foreach (var alphabet in new[] { "eng", "jp" })
    {
        var name = "gml_Object_obj_bonus_" + alphabet;
        import.QueueReplace(Data.Code.ByName(name + "_Alarm_0"), "visible = true;");
        import.QueuePrepend(Data.Code.ByName(name + "_Collision_21"), @"
var pickup = file_text_open_append(""minimalism-playtest-symbols.txt"");
if (pickup >= 0) {
    file_text_write_string(pickup, string(global.level) + "","" + string(obj_control.bot_frame) + "","" + string(id) + "","" + string(image_index + 1) + "","" + """ + alphabet + @""");
    file_text_writeln(pickup);
    file_text_close(pickup);
}
");
    }
    import.QueuePrepend(Data.Code.ByName("gml_Object_obj_door_Alarm_0"), @"
global.bot_previous_symbols = instance_number(obj_bonus_eng) + instance_number(obj_bonus_jp);
");
}

import.QueueAppend(Data.Code.ByName("gml_Object_obj_control_menu_Create_0"), @"
global.bot_seq = 0;
global.bot_action = 0;
global.bot_prev = 0;
global.bot_previous_symbols = 0;
global.bot_previous_achievement = -1;
");
if (yieldWhileWaiting)
    import.QueueAppend(Data.Code.ByName("gml_Object_obj_control_menu_Create_0"),
        "\nglobal.bot_wait_hook = external_define(working_directory + \"minimalism_wait32.dll\", \"minimalism_wait\", dll_cdecl, ty_real, 0);");
import.QueueFindReplace(Data.Code.ByName("gml_Object_obj_control_menu_Step_0"),
    "var key__accept = keyboard_check_released(vk_space)", "var key__accept = true || keyboard_check_released(vk_space)");
if (startLevel != 1)
    import.QueueFindReplace(Data.Code.ByName("gml_Object_obj_control_menu_Step_0"), "room_goto(rm_level_01);", "startLevel(" + startLevel + ");");
import.QueueAppend(Data.Code.ByName("gml_Object_obj_control_Create_0"), @"
bot_frame = 0;
bot_index = 1;
bot_plan = """";
bot_reported = false;
bot_retry = false;
global.bot_action = 0;
global.bot_prev = 0;
global.bot_death = """";
global.bot_waiting = false;
global.bot_symbol_total = 0;
room_speed = " + rate + @";
");

import.QueuePrepend(Data.Code.ByName("gml_Script_deathPlayer"), @"
var cause = object_get_name(object_index);
if (object_index == obj_player) { cause = object_get_name(other.object_index); }
with (obj_player) {
    global.bot_death = cause + "","" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6);
}
");

import.QueueReplace(controller.EventHandlerFor(EventType.Step, EventSubtypeStep.BeginStep, Data), @"
if (global.level <= 0) exit;
" + tileWindow + @"
if (bot_frame == 0 && !bot_reported) {
    global.bot_symbol_total = instance_number(obj_bonus_eng) + instance_number(obj_bonus_jp);
}
if (!instance_exists(obj_player) && !bot_retry) { bot_index = string_length(bot_plan) + 1; }
if (bot_index > string_length(bot_plan)) {
    if (!bot_reported) {
        var report = file_text_open_write(""minimalism-playtest-state-"" + string(global.bot_seq) + "".txt"");
        if (report >= 0) {
            file_text_write_string(report, string(global.level) + "","" + string(bot_frame) + "","" + string(instance_number(obj_key)) + "","" + string(global.bot_action) + "","" + string(room_speed) + "","" + string(fps_real) + "","" + string(window_get_x()) + "","" + string(window_get_y()) + "","" + string(window_get_width()) + "","" + string(window_get_height()) + "","" + string(window_has_focus()) + "","" + string(global.bot_previous_symbols) + "","" + string(global.bot_previous_achievement));
            file_text_writeln(report);
            with (obj_player) {
                file_text_write_string(report, string_format(x, 0, 6) + "","" + string_format(y, 0, 6) + "","" + string_format(hspd, 0, 6) + "","" + string_format(vspd, 0, 6) + "","" + string(grounded) + "","" + string(state) + "","" + string(jumps) + "","" + string(wall_jumps) + "","" + string(meet) + "","" + string(wall_jump_can) + "","" + string(invert_gravity) + "","" + string(alarm[0]) + "","" + string(alarm[1]));
                file_text_writeln(report);
            }
            if (!instance_exists(obj_player)) {
                file_text_write_string(report, ""death,"" + global.bot_death);
                file_text_writeln(report);
            }
            with (obj_key) {
                file_text_write_string(report, ""key,"" + string(id) + "","" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6));
                file_text_writeln(report);
            }
            with (obj_bonus_eng) {
                file_text_write_string(report, ""symbol,"" + string(id) + "","" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6));
                file_text_writeln(report);
            }
            with (obj_bonus_jp) {
                file_text_write_string(report, ""symbol,"" + string(id) + "","" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6));
                file_text_writeln(report);
            }
            with (obj_shooter_left) {
                file_text_write_string(report, ""shooter,"" + string(id) + "","" + string(alarm[0]));
                file_text_writeln(report);
            }
            with (obj_shooter_right) {
                file_text_write_string(report, ""shooter,"" + string(id) + "","" + string(alarm[0]));
                file_text_writeln(report);
            }
            with (obj_arrow_left) {
                file_text_write_string(report, ""arrow,"" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6) + "","" + string_format(hspeed, 0, 6));
                file_text_writeln(report);
            }
            with (obj_arrow_right) {
                file_text_write_string(report, ""arrow,"" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6) + "","" + string_format(hspeed, 0, 6));
                file_text_writeln(report);
            }
            with (obj_spike_fall) {
                file_text_write_string(report, ""falling,"" + string(id) + "","" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6) + "","" + string(fall_now) + "","" + string_format(spd, 0, 6));
                file_text_writeln(report);
            }
            with (obj_piston_par) {
                file_text_write_string(report, ""piston,"" + string(id) + "","" + string_format(x, 0, 6) + "","" + string_format(y, 0, 6) + "","" + string(direction_piston) + "","" + string_format(speed_piston, 0, 6));
                file_text_writeln(report);
            }
            file_text_write_string(report, ""end"");
            file_text_close(report);
        }
        bot_reported = true;
    }
    var path = ""minimalism-playtest-move-"" + string(global.bot_seq) + "".txt"";
    var deadline = get_timer() + 180000000;
    while (!file_exists(path) && get_timer() < deadline) { " + (yieldWhileWaiting ? "external_call(global.bot_wait_hook);" : "") + @" }
    if (!file_exists(path)) { game_end(); exit; }
    var file = file_text_open_read(path);
    bot_plan = file_text_read_string(file);
    file_text_close(file);
    if (bot_plan == ""stop"") { game_end(); exit; }
    global.bot_seq += 1;
    if (bot_plan == ""restart"") { room_restart(); exit; }
    bot_retry = bot_plan == ""retry"";
    if (bot_retry) { bot_plan = ""4000000000000000000000000""; }
    bot_index = 1;
    bot_reported = false;
}
global.bot_prev = global.bot_action;
global.bot_action = real(string_char_at(bot_plan, bot_index));
bot_index += 1;
bot_frame += 1;
global.bot_waiting = bot_index > string_length(bot_plan);
if (room_speed > 60) { draw_enable_drawevent(bot_frame mod 5 == 0 || global.bot_waiting); }
");

import.QueueAppend(Data.Code.ByName("gml_Object_obj_text_end_Create_0"), @"
draw_enable_drawevent(true);
var report = file_text_open_write(""minimalism-playtest-finished.txt"");
if (report >= 0) {
    file_text_write_string(report, room_get_name(room));
    file_text_writeln(report);
    file_text_write_string(report, string(global.bot_previous_symbols));
    file_text_writeln(report);
    file_text_write_string(report, string(global.bot_previous_achievement));
    file_text_close(report);
}
");

import.Import();
Console.WriteLine("Prepared Minimalism playtest at " + rate + " steps per second.");
