using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using UndertaleModLib.Models;
using UndertaleModLib.Util;

var trackedParameters = new HashSet<string>
{
    "dir", "direction_piston", "dir_shuriken", "image_index", "spd", "speed_back",
    "speed_go", "speed_piston", "speed_shuriken", "spike_id",
    "time_crash", "time_gravity", "time_wait",
};
var decompiler = new GlobalDecompileContext(Data);
var decompileSettings = Data.ToolInfo.DecompilerSettings;
var assignment = new Regex(@"(?:^|(?<=;))\s*(\w+)\s*=\s*(-?\d+(?:\.\d+)?)\s*;", RegexOptions.Multiline);

Dictionary<string, double> InstanceSettings(UndertaleCode code)
{
    var settings = new Dictionary<string, double>();
    if (code == null)
        return settings;

    var source = new Underanalyzer.Decompiler.DecompileContext(decompiler, code, decompileSettings).DecompileToString();
    foreach (Match match in assignment.Matches(source))
    {
        string name = match.Groups[1].Value;
        if (trackedParameters.Contains(name))
            settings[name] = double.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture);
    }
    return settings;
}

var rooms = Data.Rooms.Select(room => new
{
    name = room.Name.Content,
    width = room.Width,
    height = room.Height,
    speed = room.Speed,
    code = room.CreationCodeId?.Name.Content,
    views = room.Views.Where(view => view.Enabled).Select(view => new
    {
        x = view.ViewX,
        y = view.ViewY,
        width = view.ViewWidth,
        height = view.ViewHeight,
        follows = view.ObjectId?.Name.Content,
    }).ToArray(),
    instances = room.GameObjects.Select(instance => new
    {
        name = instance.ObjectDefinition?.Name.Content,
        id = instance.InstanceID,
        x = instance.X,
        y = instance.Y,
        scaleX = instance.ScaleX,
        scaleY = instance.ScaleY,
        rotation = instance.Rotation,
        code = instance.CreationCode?.Name.Content,
        settings = InstanceSettings(instance.CreationCode),
    }).ToArray(),
    tiles = room.Tiles.Select(tile => new
    {
        x = tile.X,
        y = tile.Y,
        width = tile.Width,
        height = tile.Height,
        depth = tile.TileDepth,
        scaleX = tile.ScaleX,
        scaleY = tile.ScaleY,
        sourceX = tile.SourceX,
        sourceY = tile.SourceY,
        background = tile.BackgroundDefinition?.Name.Content,
        sprite = tile.SpriteDefinition?.Name.Content,
    }).ToArray(),
}).ToArray();

var objects = Data.GameObjects.ToDictionary(item => item.Name.Content, item => new
{
    sprite = item.Sprite?.Name.Content,
    mask = item.TextureMaskId?.Name.Content,
    parent = item.ParentId?.Name.Content,
    solid = item.Solid,
    visible = item.Visible,
    depth = item.Depth,
});

var sprites = Data.Sprites.ToDictionary(sprite => sprite.Name.Content, sprite => new
{
    width = sprite.Width,
    height = sprite.Height,
    originX = sprite.OriginX,
    originY = sprite.OriginY,
    left = sprite.MarginLeft,
    right = sprite.MarginRight,
    top = sprite.MarginTop,
    bottom = sprite.MarginBottom,
    maskKind = sprite.SepMasks.ToString(),
    bitmapMasks = sprite.CollisionMasks.Select(mask => mask.Data).ToArray(),
});

var destination = Environment.GetEnvironmentVariable("MINIMALISM_ROOM_METADATA");
if (string.IsNullOrEmpty(destination))
    throw new InvalidOperationException("Set MINIMALISM_ROOM_METADATA to the output JSON path.");

File.WriteAllText(destination, JsonSerializer.Serialize(new { schema = 2, rooms, objects, sprites }));
