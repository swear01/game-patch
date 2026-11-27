using System;
using System.Collections.Generic;
using UnityEngine;

public static class TimberRushAutoUpgrade
{
    public static int Choose(
        List<StatModifier> cards, Stats stats, HashSet<StatType> banishedStats,
        ref int banishesRemaining, StatRarity? forcedRarity, int stackCount, int source,
        Func<double, List<StatModifier>, StatRarity?, int, StatModifier> generateReplacement)
    {
        if (cards.Count == 0)
            return -1;

        var build = new RunBuild(stats);
        int best = BestCard(cards, build);
        if (source != (int)TestStats_Dev.UpgradePanelSource.LevelUp || best < 0 ||
            cards.Count < 2 || banishesRemaining <= 0 || build.Value(cards[best]) < 0.04)
            return best;

        int banish = -1;
        int banishPriority = 0;
        for (int i = 0; i < cards.Count; i++)
        {
            if (i == best || cards[i]?.StatDefinition == null)
                continue;

            StatType type = cards[i].StatDefinition.Type;
            int priority = build.BanishPriority(type);
            if (priority > banishPriority && !banishedStats.Contains(type))
            {
                banish = i;
                banishPriority = priority;
            }
        }

        if (banish < 0)
            return best;

        // Use the usual card pool, keeping the old type excluded until the replacement is rolled.
        StatModifier replacement = generateReplacement(stats.GetStatValue(StatType.Luck), cards, forcedRarity, stackCount);
        if (replacement?.StatDefinition == null)
            return best;

        banishedStats.Add(cards[banish].StatDefinition.Type);
        banishesRemaining--;
        cards[banish] = replacement;
        return BestCard(cards, build);
    }

    private static int BestCard(List<StatModifier> cards, RunBuild build)
    {
        int best = -1;
        double bestScore = double.NegativeInfinity;
        for (int i = 0; i < cards.Count; i++)
        {
            StatModifier card = cards[i];
            if (card?.StatDefinition == null)
                continue;

            int rarity = card.IsMythical ? (int)StatRarity.Legendary + 1 : (int)card.Rarity;
            double value = build.Value(card);
            double score = value + rarity * (value > 0.0 ? 0.018 : 0.001);
            if (score > bestScore)
            {
                best = i;
                bestScore = score;
            }
        }
        return best;
    }

    private sealed class RunBuild
    {
        private readonly Stats stats;
        private readonly int level;
        private readonly bool maxLevel;
        private readonly bool hasCrew;
        private readonly bool overflowCriticals;
        private readonly double crewShare;
        private readonly double lightningShare;
        private readonly double magmaShare;

        public RunBuild(Stats stats)
        {
            this.stats = stats;
            var levels = LevelAndCurrencyManager.Instance;
            level = levels ? levels.GetCurrentLevel() : 1;
            maxLevel = levels && levels.IsMaxLevel;
            if (!stats)
                return;

            overflowCriticals = stats.HasPrestigeEffect(PrestigeEffect.OverflowCriticals);
            hasCrew = stats.GetStatValue(StatType.LumberjackAmount) >= 1.0;
            var crew = hasCrew ? UnityEngine.Object.FindFirstObjectByType<LumberjackManager>() : null;
            double crewDamage = 0.0;
            if (crew)
            {
                foreach (double damage in crew.GetRunDamages())
                    crewDamage = GameNumbers.AddNonNegative(crewDamage, damage);
            }

            // Normalize before adding so the shares still work on high-Prestige runs.
            double player = Math.Max(RunDamageTracker.NormalDamage, RunDamageTracker.CritDamage);
            double lightning = RunDamageTracker.LightningDamage;
            double magma = RunDamageTracker.MagmaDamage;
            double scale = Math.Max(Math.Max(player, crewDamage), Math.Max(lightning, magma));
            if (scale <= 0.0)
                return;

            double total = RunDamageTracker.NormalDamage / scale + RunDamageTracker.CritDamage / scale +
                           crewDamage / scale + lightning / scale + magma / scale;
            crewShare = crewDamage / scale / total;
            lightningShare = lightning / scale / total;
            magmaShare = magma / scale / total;
        }

        public double Value(StatModifier card)
        {
            if (!stats)
                return 0.0;

            StatType type = card.StatDefinition.Type;
            double before = stats.GetStatValue(type);
            double after = stats.PreviewModifier(card);
            double gain = LogGain(before, after);
            double early = level < 18 ? 1.0 : 0.35;
            double playerWeight = 1.0 - crewShare * 0.7;
            double crewWeight = hasCrew ? 0.25 + crewShare * 0.75 : 0.0;
            switch (type)
            {
                case StatType.Damage:
                    return gain * playerWeight;
                case StatType.AttackSpeed:
                    return gain * Math.Max(0.2, playerWeight - 0.65 * (lightningShare + magmaShare));
                case StatType.CritChance:
                case StatType.CritDamage:
                    return CritGain(type, after, StatType.CritChance, StatType.CritDamage, false) * playerWeight;
                case StatType.LumberjackDamage:
                case StatType.LumberjackSpeed:
                    return gain * crewWeight;
                case StatType.LumberjackCritChance:
                case StatType.LumberjackCritDamage:
                    return CritGain(type, after, StatType.LumberjackCritChance, StatType.LumberjackCritDamage, true) * crewWeight;
                case StatType.DamagePerLevelMultiplier:
                    return PerUnitGain(before, after, level - 1) * playerWeight;
                case StatType.DamagePerDroneMultiplier:
                    return PerUnitGain(before, after, Math.Floor(stats.GetStatValue(StatType.DroneAmount))) * playerWeight;
                case StatType.DamagePerLumberjackMultiplier:
                    return PerUnitGain(before, after, Math.Round(stats.GetStatValue(StatType.LumberjackAmount))) * playerWeight;
                case StatType.DamagePerSpecialLogMultiplier:
                    return PerUnitGain(before, after, SpecialLogsUnlocked()) * playerWeight;
                case StatType.LightningDamageMultiplier:
                    return gain * (0.10 + lightningShare * 0.9);
                case StatType.MagmaDamageMultiplier:
                case StatType.MagmaDuration:
                    return gain * (0.10 + magmaShare * 0.9);
                case StatType.LogValueMultiplier:
                    return gain;
                case StatType.DoubleLogValueChance:
                    return LogGain(1.0 + GameNumbers.Clamp01(before), 1.0 + GameNumbers.Clamp01(after));
                case StatType.ExperienceMultiplier:
                    return maxLevel ? 0.0 : gain * early * 0.8;
                case StatType.Luck:
                    return LogGain(1.0 + before, 1.0 + after) * early * 0.8;
                case StatType.ChestRate:
                    return LogGain(0.08 + GameNumbers.Clamp01(before), 0.08 + GameNumbers.Clamp01(after)) * early * 0.8;
                case StatType.DroneAmount:
                    return LogGain(1.0 + Math.Floor(before), 1.0 + Math.Floor(after)) * 0.55;
                case StatType.MagnetRadius:
                case StatType.DroneSpeed:
                case StatType.AttackDistance:
                case StatType.MoveSpeed:
                    return gain * 0.16;
                case StatType.AutoCollectChance:
                    return LogGain(0.3 + GameNumbers.Clamp01(before), 0.3 + GameNumbers.Clamp01(after)) * 0.3;
                default:
                    return IsCoinOnly(type) ? 0.015 * Math.Min(gain, 1.0) : 0.035 * Math.Min(gain, 1.0);
            }
        }

        public int BanishPriority(StatType type)
        {
            // Temporary effects can cap a stat without making its upgrades useless for the run.
            bool capped = (type == StatType.DoubleLogValueChance || type == StatType.ChestRate ||
                           type == StatType.AutoCollectChance) && stats.GetStatValue(type) >= 1.0;
            if (type == StatType.CritChance && !overflowCriticals &&
                !Stats.StatUnlocked(StatType.LightningLogUnlocked) && !Stats.StatUnlocked(StatType.MagmaLogUnlocked) &&
                (!hasCrew || stats.GetStatValue(StatType.LumberjackPlayerCritChancePercent) <= 0.0))
                capped = stats.GetStatValue(type) >= 1.0;

            if (capped && !stats.BuffModifiers.Exists(modifier => modifier.StatDefinition.Type == type))
                return 3;
            if (level >= 18 && IsCoinOnly(type))
                return 2;
            if (level >= 30 &&
                ((type == StatType.LightningDamageMultiplier && lightningShare < 0.02) ||
                 (type == StatType.MagmaDamageMultiplier && magmaShare < 0.02)) &&
                !stats.RunModifiers.Exists(modifier => modifier.StatDefinition.Type == type))
                return 1;
            return 0;
        }

        private double CritGain(StatType type, double after, StatType chanceType, StatType damageType, bool crew)
        {
            double chance = stats.GetStatValue(chanceType);
            double damage = crew ? stats.GetStatValue(damageType) : stats.GetRawStatValue(damageType);
            double nextChance = type == chanceType ? after : chance;
            double nextDamage = type == damageType ? after : damage;
            if (!crew && overflowCriticals && type == damageType)
                nextDamage /= Math.Max(1.0, chance); // PreviewModifier already applies player overflow.

            double current = ExpectedCrit(chance, stats.ApplyOverflowCriticals(damage, chance));
            double improved = ExpectedCrit(nextChance, stats.ApplyOverflowCriticals(nextDamage, nextChance));
            return LogGain(current, improved);
        }

        private static double ExpectedCrit(double chance, double damage)
        {
            return 1.0 + GameNumbers.Clamp01(chance) * (Math.Max(1.0, damage) - 1.0);
        }

        private int SpecialLogsUnlocked()
        {
            int count = 0;
            if (Stats.StatUnlocked(StatType.LightningLogUnlocked)) count++;
            if (Stats.StatUnlocked(StatType.MagmaLogUnlocked)) count++;
            if (Stats.StatUnlocked(StatType.GoldenLogUnlocked)) count++;
            if (Stats.StatUnlocked(StatType.ArcaneLogUnlocked)) count++;
            if (Stats.StatUnlocked(StatType.MagnetLogUnlocked)) count++;
            if (Stats.StatUnlocked(StatType.CrystalLogUnlocked)) count++;
            return count;
        }
    }

    private static double PerUnitGain(double before, double after, double count)
    {
        if (count <= 0.0)
            return 0.0;
        double baseline = 1.0 / count;
        return LogGain(baseline + Math.Max(0.0, before), baseline + Math.Max(0.0, after));
    }

    private static double LogGain(double before, double after)
    {
        if (after <= before || double.IsNaN(after) || double.IsNaN(before))
            return 0.0;
        return Math.Log(Math.Max(0.01, after)) - Math.Log(Math.Max(0.01, before));
    }

    private static bool IsCoinOnly(StatType type)
    {
        return type == StatType.GoldMultiplier || type == StatType.CoinAmount || type == StatType.CoinSpawnChance ||
               type == StatType.DoubleCoinValueChance || type == StatType.LogToCoinChance || type == StatType.GoldenDuration;
    }
}
