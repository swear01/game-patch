using System;
using System.Collections.Generic;

public static class ShelldiverDynamicRoute
{
    public sealed class Point
    {
        public double X;
        public double Y;
    }

    public sealed class Hazard
    {
        public double X;
        public double Y;
        public double Vx;
        public double Vy;
        public double BodyRadius;
        public double BlastRadius;

        // A positive value is the first possible blast step relative to the start.
        // Zero means the blast could occur immediately.
        public int BlastNotBefore;

        // Positive cost permits a blast-only crossing. Zero keeps the blast as a hard constraint.
        public double BlastCostSteps;
    }

    private const double Epsilon = 1e-8;
    private const double TimeBucketSteps = 3.0;
    private static readonly Point[] NoPath = new Point[0];
    private static readonly Hazard[] NoHazards = new Hazard[0];
    private static readonly int[] NeighborX = { -1, 0, 1, -1, 1, -1, 0, 1 };
    private static readonly int[] NeighborY = { -1, -1, -1, 0, 0, 1, 1, 1 };

    // Time is in simulation steps. Each segment assumes uninterrupted movement at
    // pixelsPerStep, so a caller should replan from fresh telemetry after a pulse.
    public static Point[] Find(string[] rows, int tileWidth, int tileHeight,
        double fromX, double fromY, double toX, double toY, double terrainMargin,
        double pixelsPerStep, int maxNodes, Hazard[] hazards)
    {
        if (rows == null || rows.Length == 0 || string.IsNullOrEmpty(rows[0]) ||
            tileWidth < 1 || tileHeight < 1 || maxNodes < 1 ||
            !Finite(terrainMargin) || terrainMargin < 0 ||
            !Finite(pixelsPerStep) || pixelsPerStep <= 0 ||
            !Finite(fromX) || !Finite(fromY) || !Finite(toX) || !Finite(toY))
            return NoPath;

        for (int y = 1; y < rows.Length; ++y)
            if (rows[y] == null || rows[y].Length != rows[0].Length)
                return NoPath;

        hazards = hazards ?? NoHazards;
        bool timeMatters = false;
        foreach (Hazard hazard in hazards)
        {
            if (hazard == null || !Finite(hazard.X) || !Finite(hazard.Y) ||
                !Finite(hazard.Vx) || !Finite(hazard.Vy) ||
                !Finite(hazard.BodyRadius) || hazard.BodyRadius < 0 ||
                !Finite(hazard.BlastRadius) || hazard.BlastRadius < 0 || hazard.BlastNotBefore < 0 ||
                !Finite(hazard.BlastCostSteps) || hazard.BlastCostSteps < 0)
                return NoPath;
            if ((hazard.BodyRadius > 0 || hazard.BlastRadius > 0) &&
                (hazard.Vx != 0 || hazard.Vy != 0 || (hazard.BlastRadius > 0 && hazard.BlastNotBefore > 0)))
                timeMatters = true;
        }

        var terrain = new Terrain(rows, tileWidth, tileHeight, terrainMargin);
        if (!terrain.Clear(fromX, fromY, fromX, fromY) || !terrain.Clear(toX, toY, toX, toY))
            return NoPath;

        double length = Distance(fromX, fromY, toX, toY);
        if (length <= Epsilon || !Finite(length / pixelsPerStep))
            return NoPath;
        var goal = new Point { X = toX, Y = toY };
        double initialCost = InitialBlastCost(hazards, fromX, fromY);
        if (!Finite(initialCost))
            return NoPath;

        double directTime = length / pixelsPerStep;
        double directBlastCost;
        double bestGoalCost = double.PositiveInfinity;
        double bestGoalTime = 0;
        Node bestGoalTail = null;
        if (terrain.Clear(fromX, fromY, toX, toY) &&
            CheckHazards(hazards, fromX, fromY, toX, toY, 0, directTime, out directBlastCost))
        {
            if (directBlastCost == 0)
                return new[] { goal };
            bestGoalCost = initialCost + directTime + directBlastCost;
            bestGoalTime = directTime;
        }

        // Half-tile spacing resolves corridors that have less than one tile of
        // remaining width once the player's clearance is applied.
        double stepX = tileWidth / 2.0;
        double stepY = tileHeight / 2.0;
        int columns = checked(rows[0].Length * 2);
        int lines = checked(rows.Length * 2);
        var cellClear = new byte[checked(columns * lines)];
        double goalReach = Distance(0, 0, stepX, stepY) * 2.0;
        var open = new MinHeap();
        var best = new Dictionary<long, Node>();
        int ordinal = 0;

        int startColumn = (int)(fromX / stepX);
        int startLine = (int)(fromY / stepY);
        for (int y = Math.Max(0, startLine - 2); y <= Math.Min(lines - 1, startLine + 2); ++y)
        {
            for (int x = Math.Max(0, startColumn - 2); x <= Math.Min(columns - 1, startColumn + 2); ++x)
            {
                double px = (x + 0.5) * stepX;
                double py = (y + 0.5) * stepY;
                double time = Distance(fromX, fromY, px, py) / pixelsPerStep;
                double blastCost;
                if (!terrain.Clear(fromX, fromY, px, py) ||
                    !CheckHazards(hazards, fromX, fromY, px, py, 0, time, out blastCost))
                    continue;

                int cell = y * columns + x;
                cellClear[cell] = 1;
                Enqueue(open, best, timeMatters, pixelsPerStep, goal, cell, px, py,
                    time, initialCost + time + blastCost, null, ref ordinal);
            }
        }

        for (int expanded = 0; open.Count != 0 && expanded < maxNodes;)
        {
            Node here = open.Pop();
            if (here.Priority > bestGoalCost + Epsilon)
                break;
            if (!ReferenceEquals(best[StateKey(here.Cell, here.Time, timeMatters)], here))
                continue;
            ++expanded;

            double toGoal = Distance(here.X, here.Y, toX, toY);
            double goalTime = toGoal / pixelsPerStep;
            double goalBlastCost;
            if (toGoal <= goalReach && terrain.Clear(here.X, here.Y, toX, toY) &&
                CheckHazards(hazards, here.X, here.Y, toX, toY, here.Time, goalTime, out goalBlastCost))
            {
                double total = here.Cost + goalTime + goalBlastCost;
                double finishTime = here.Time + goalTime;
                // At the same total cost, more travel time means less blast exposure.
                if (total < bestGoalCost - Epsilon ||
                    (Math.Abs(total - bestGoalCost) <= Epsilon && finishTime > bestGoalTime + Epsilon))
                {
                    bestGoalCost = total;
                    bestGoalTime = finishTime;
                    bestGoalTail = here;
                }
                if (bestGoalCost <= here.Priority + Epsilon && bestGoalCost - bestGoalTime <= initialCost + Epsilon)
                    break;
            }

            int column = here.Cell % columns;
            int line = here.Cell / columns;
            for (int direction = 0; direction < NeighborX.Length; ++direction)
            {
                int x = column + NeighborX[direction], y = line + NeighborY[direction];
                if ((uint)x >= (uint)columns || (uint)y >= (uint)lines)
                    continue;
                int cell = y * columns + x;
                if (cellClear[cell] == 2)
                    continue;

                double px = (x + 0.5) * stepX;
                double py = (y + 0.5) * stepY;
                if (cellClear[cell] == 0)
                    cellClear[cell] = terrain.Clear(px, py, px, py) ? (byte)1 : (byte)2;
                if (cellClear[cell] == 2)
                    continue;

                double elapsed = Distance(here.X, here.Y, px, py) / pixelsPerStep;
                double arrival = here.Time + elapsed;
                double cost = here.Cost + elapsed;
                Node previous;
                best.TryGetValue(StateKey(cell, arrival, timeMatters), out previous);
                if (!Improves(previous, cost, arrival))
                    continue;
                double blastCost;
                if (!terrain.Clear(here.X, here.Y, px, py) ||
                    !CheckHazards(hazards, here.X, here.Y, px, py, here.Time, elapsed, out blastCost))
                    continue;
                cost += blastCost;
                if (Improves(previous, cost, arrival))
                    Enqueue(open, best, timeMatters, pixelsPerStep, goal, cell, px, py,
                        arrival, cost, here, ref ordinal);
            }
        }

        if (bestGoalTail != null)
            return BuildRoute(bestGoalTail, goal, fromX, fromY, terrain, hazards, pixelsPerStep);
        return Finite(bestGoalCost) ? new[] { goal } : NoPath;
    }

    private static bool Improves(Node previous, double cost, double time)
    {
        return Finite(cost) && (previous == null || cost < previous.Cost - Epsilon ||
            (Math.Abs(cost - previous.Cost) <= Epsilon && time < previous.Time - Epsilon));
    }

    private static void Enqueue(MinHeap open, Dictionary<long, Node> best, bool timeMatters,
        double speed, Point goal, int cell, double x, double y, double time, double cost, Node parent, ref int ordinal)
    {
        var node = new Node
        {
            Cell = cell, X = x, Y = y, Time = time, Cost = cost, Parent = parent, Order = ordinal++,
            // Remaining travel time is a lower bound. The exposure cost cannot be negative.
            Priority = cost + Distance(x, y, goal.X, goal.Y) / speed
        };
        best[StateKey(cell, time, timeMatters)] = node;
        open.Push(node);
    }

    private static long StateKey(int cell, double time, bool timeMatters)
    {
        // Nearby arrival times share a state, but a different lane can reach
        // the same cell after a moving hazard has cleared it.
        long bucket = timeMatters ? (long)Math.Min(int.MaxValue, Math.Floor(time / TimeBucketSteps)) : 0;
        return (bucket << 32) | (uint)cell;
    }

    private static Point[] BuildRoute(Node tail, Point goal, double fromX, double fromY,
        Terrain terrain, Hazard[] hazards, double speed)
    {
        var path = new List<Point> { goal };
        for (Node node = tail; node != null; node = node.Parent)
        {
            Point next = path[path.Count - 1];
            if (Distance(node.X, node.Y, next.X, next.Y) > Epsilon &&
                (node.Parent != null || Distance(node.X, node.Y, fromX, fromY) > Epsilon))
                path.Add(new Point { X = node.X, Y = node.Y });
        }
        path.Reverse();

        var result = new List<Point>();
        int first = 0;
        double time = 0;
        while (first < path.Count)
        {
            int end = path.Count - 1;
            if (hazards.Length != 0)
            {
                // Preserve the timing of later hazard crossings. Only collapse
                // straight segments moving in the same direction.
                end = first;
                double dx = path[first].X - fromX, dy = path[first].Y - fromY;
                while (end + 1 < path.Count)
                {
                    double ex = path[end + 1].X - path[end].X;
                    double ey = path[end + 1].Y - path[end].Y;
                    if (Math.Abs(dx * ey - dy * ex) > Epsilon || dx * ex + dy * ey <= 0)
                        break;
                    ++end;
                }
            }
            while (end > first)
            {
                Point candidate = path[end];
                double duration = Distance(fromX, fromY, candidate.X, candidate.Y) / speed;
                double ignoredCost;
                if (terrain.Clear(fromX, fromY, candidate.X, candidate.Y) &&
                    CheckHazards(hazards, fromX, fromY, candidate.X, candidate.Y, time, duration, out ignoredCost))
                    break;
                --end;
            }

            Point next = path[end];
            time += Distance(fromX, fromY, next.X, next.Y) / speed;
            result.Add(next);
            fromX = next.X;
            fromY = next.Y;
            first = end + 1;
        }
        return result.ToArray();
    }

    private static double InitialBlastCost(Hazard[] hazards, double x, double y)
    {
        double cost = 0;
        foreach (Hazard hazard in hazards)
        {
            if (hazard.BlastCostSteps > 0 && hazard.BlastNotBefore == 0 &&
                InsideRadius(x - hazard.X, y - hazard.Y, hazard.BlastRadius))
                cost += hazard.BlastCostSteps;
        }
        return cost;
    }

    private static bool CheckHazards(Hazard[] hazards, double x, double y, double toX, double toY,
        double time, double duration, out double blastCost)
    {
        blastCost = 0;
        foreach (Hazard hazard in hazards)
        {
            double outer = Math.Max(hazard.BodyRadius, hazard.BlastRadius);
            if (outer == 0)
                continue;

            double rx = x - (hazard.X + hazard.Vx * time);
            double ry = y - (hazard.Y + hazard.Vy * time);
            double dx = toX - x - hazard.Vx * duration;
            double dy = toY - y - hazard.Vy * duration;
            if (Math.Min(rx, rx + dx) > outer || Math.Max(rx, rx + dx) < -outer ||
                Math.Min(ry, ry + dy) > outer || Math.Max(ry, ry + dy) < -outer)
                continue;

            if (hazard.BodyRadius > 0 && !RadiusClear(rx, ry, dx, dy, hazard.BodyRadius, true))
                return false;
            if (hazard.BlastRadius <= 0 || time + duration < hazard.BlastNotBefore)
                continue;

            // A known fuse only exposes the part of the sweep at or after activation.
            double start = duration > Epsilon ? Math.Max(0, (hazard.BlastNotBefore - time) / duration) : 0;
            bool allowEscape = hazard.BlastCostSteps == 0 && hazard.BlastNotBefore == 0;
            if (RadiusClear(rx + dx * start, ry + dy * start, dx * (1 - start), dy * (1 - start),
                hazard.BlastRadius, allowEscape))
                continue;
            if (hazard.BlastCostSteps == 0)
                return false;

            // One charge per hazard per continuous exposure. A segment that
            // starts already exposed was charged upon entry or at the route origin.
            if (time < hazard.BlastNotBefore || !InsideRadius(rx, ry, hazard.BlastRadius))
                blastCost += hazard.BlastCostSteps;
        }
        return Finite(blastCost);
    }

    private static bool InsideRadius(double x, double y, double radius)
    {
        return x * x + y * y + Epsilon < radius * radius;
    }

    private static bool RadiusClear(double x, double y, double dx, double dy, double radius, bool allowEscape)
    {
        double start = x * x + y * y;
        double movement = dx * dx + dy * dy;
        double t = movement > Epsilon ? Math.Max(0, Math.Min(1, -(x * dx + y * dy) / movement)) : 0;
        double nearestX = x + dx * t, nearestY = y + dy * t;
        double nearest = nearestX * nearestX + nearestY * nearestY;
        double limit = radius * radius;
        if (nearest + Epsilon >= limit)
            return true;
        if (!allowEscape || start >= limit || nearest + Epsilon < start)
            return false;

        // Starting inside an unknown blast or contact radius only permits
        // motion that immediately separates and ends farther from the hazard.
        double endX = x + dx, endY = y + dy;
        return endX * endX + endY * endY > start + Epsilon;
    }

    private static double Distance(double x, double y, double toX, double toY)
    {
        double dx = toX - x, dy = toY - y;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    private static bool Finite(double value)
    {
        return !double.IsNaN(value) && !double.IsInfinity(value);
    }

    private sealed class Terrain
    {
        private readonly string[] rows;
        private readonly int[,] occupied;
        private readonly int tileWidth;
        private readonly int tileHeight;
        private readonly double margin;

        public Terrain(string[] rows, int tileWidth, int tileHeight, double margin)
        {
            this.rows = rows;
            this.tileWidth = tileWidth;
            this.tileHeight = tileHeight;
            this.margin = margin;
            occupied = new int[rows.Length + 1, rows[0].Length + 1];
            for (int row = 0; row < rows.Length; ++row)
            {
                int count = 0;
                for (int column = 0; column < rows[row].Length; ++column)
                {
                    if (rows[row][column] != '.')
                        ++count;
                    occupied[row + 1, column + 1] = occupied[row, column + 1] + count;
                }
            }
        }

        public bool Clear(double x, double y, double toX, double toY)
        {
            double left = Math.Min(x, toX) - margin, right = Math.Max(x, toX) + margin;
            double top = Math.Min(y, toY) - margin, bottom = Math.Max(y, toY) + margin;
            if (left < 0 || top < 0 || right >= (double)rows[0].Length * tileWidth ||
                bottom >= (double)rows.Length * tileHeight)
                return false;

            int x1 = (int)(left / tileWidth), x2 = (int)(right / tileWidth);
            int y1 = (int)(top / tileHeight), y2 = (int)(bottom / tileHeight);
            if (occupied[y2 + 1, x2 + 1] - occupied[y1, x2 + 1] -
                occupied[y2 + 1, x1] + occupied[y1, x1] == 0)
                return true;

            double dx = toX - x, dy = toY - y;
            for (int row = y1; row <= y2; ++row)
            {
                for (int column = x1; column <= x2; ++column)
                {
                    if (rows[row][column] == '.')
                        continue;
                    double enter = 0, leave = 1;
                    if (Clip(x, dx, (double)column * tileWidth - margin,
                            (double)(column + 1) * tileWidth + margin, ref enter, ref leave) &&
                        Clip(y, dy, (double)row * tileHeight - margin,
                            (double)(row + 1) * tileHeight + margin, ref enter, ref leave))
                        return false;
                }
            }
            return true;
        }

        private static bool Clip(double origin, double delta, double minimum, double maximum,
            ref double enter, ref double leave)
        {
            if (Math.Abs(delta) <= Epsilon)
                return origin >= minimum && origin <= maximum;
            double first = (minimum - origin) / delta, last = (maximum - origin) / delta;
            enter = Math.Max(enter, Math.Min(first, last));
            leave = Math.Min(leave, Math.Max(first, last));
            return enter <= leave;
        }
    }

    private sealed class Node
    {
        public int Cell;
        public int Order;
        public double X;
        public double Y;
        public double Time;
        public double Cost;
        public double Priority;
        public Node Parent;
    }

    private sealed class MinHeap
    {
        private readonly List<Node> nodes = new List<Node>();
        public int Count { get { return nodes.Count; } }

        public void Push(Node node)
        {
            int index = nodes.Count;
            nodes.Add(node);
            while (index > 0)
            {
                int parent = (index - 1) / 2;
                if (!Before(node, nodes[parent]))
                    break;
                nodes[index] = nodes[parent];
                index = parent;
            }
            nodes[index] = node;
        }

        public Node Pop()
        {
            Node first = nodes[0], last = nodes[nodes.Count - 1];
            nodes.RemoveAt(nodes.Count - 1);
            int index = 0;
            while (index * 2 + 1 < nodes.Count)
            {
                int child = index * 2 + 1;
                if (child + 1 < nodes.Count && Before(nodes[child + 1], nodes[child]))
                    ++child;
                if (!Before(nodes[child], last))
                    break;
                nodes[index] = nodes[child];
                index = child;
            }
            if (nodes.Count != 0)
                nodes[index] = last;
            return first;
        }

        private static bool Before(Node left, Node right)
        {
            if (left.Priority != right.Priority)
                return left.Priority < right.Priority;
            if (left.Time != right.Time)
                return left.Time > right.Time;
            return left.Order < right.Order;
        }
    }
}
