global.__codexTotalSteps += 1;
if (keyboard_check_pressed(vk_f6))
{
    switch (global.__codexDrawStride)
    {
        case 1: global.__codexDrawStride = 5; break;
        case 5: global.__codexDrawStride = 10; break;
        default: global.__codexDrawStride = 1; break;
    }
}
var _codexDraw = true;
if (room == rmArena && sectionGame == "action" && global.runPhase == "action" && !global.pause)
{
    _codexDraw = (global.__codexTotalSteps mod global.__codexDrawStride) == 0;
}
draw_enable_drawevent(_codexDraw);
if (_codexDraw) global.__codexDrawFrames += 1;
if (keyboard_check_pressed(vk_f7))
{
    var _codexFile = file_text_open_append("codex_draw_benchmark.log");
    file_text_write_string(_codexFile, string(global.__codexTotalSteps) + "," + string(global.__codexDrawStride) + "," + string(global.__codexDrawFrames) + "," + string(runTimer) + "," + string(runShapes) + "," + string(runMoney) + "," + string(global.runPhase) + "," + string(crosshairX) + "," + string(crosshairY) + "," + string(crosshairDir));
    file_text_writeln(_codexFile);
    file_text_close(_codexFile);
}
