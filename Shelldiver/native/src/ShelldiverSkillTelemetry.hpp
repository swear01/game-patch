#pragma once

// Included inside the bridge's private namespace after the native read helpers.
namespace skillTelemetry
{
constexpr size_t maxNodes = 640;
constexpr size_t maxEntries = 64;

Json ReadValue(RValue* value, size_t arrayDepth = 0)
{
    if (!value)
        return nullptr;

    switch (value->m_Kind)
    {
    case VALUE_STRING:
    {
        auto text = value->ToString();
        return text.size() <= 128 ? Json(text) : Json(nullptr);
    }
    case VALUE_BOOL:
        return value->ToBoolean();
    case VALUE_INT32:
    case VALUE_INT64:
    case VALUE_REF:
        return value->ToInt64();
    case VALUE_REAL:
    {
        const auto number = value->ToDouble();
        return std::isfinite(number) ? Json(number) : Json(nullptr);
    }
    case VALUE_ARRAY:
    {
        if (!arrayDepth)
            return nullptr;
        size_t size = 0;
        if (!AurieSuccess(game->GetArraySize(*value, size)))
            return nullptr;

        Json entries = Json::array();
        for (size_t index = 0; index < std::min(size, maxEntries); ++index)
        {
            RValue* entry = nullptr;
            game->GetArrayEntry(*value, index, entry);
            entries.push_back(ReadValue(entry, arrayDepth - 1));
        }
        return entries;
    }
    default:
        return nullptr;
    }
}

Json ReadField(const RValue& skill, const char* key, size_t arrayDepth = 0)
{
    return ReadValue(TryStructMember(&skill, key), arrayDepth);
}

Json ForRank(const Json& values, size_t rank)
{
    if (!values.is_array())
        return values;
    return rank < values.size() ? values[rank] : Json(nullptr);
}

void AddSkill(Json& nodes, std::string key, RValue* skill, bool& truncated)
{
    if (!skill || skill->m_Kind != VALUE_OBJECT)
        return;
    if (auto* nested = TryStructMember(skill, "skill"); nested && nested->m_Kind == VALUE_OBJECT)
        skill = nested;

    if (!key.starts_with("o_skill_"))
    {
        auto name = ReadField(*skill, "name");
        if (!name.is_string())
            return;
        key = name.get<std::string>();
    }
    if (!key.starts_with("o_skill_") || key.size() > 128 || nodes.contains(key))
        return;
    if (nodes.size() >= maxNodes)
    {
        truncated = true;
        return;
    }

    const auto rank = ReadField(*skill, "level");
    const auto maxRank = ReadField(*skill, "level_max");
    const auto costs = ReadField(*skill, "prices", 2);
    const auto currencies = ReadField(*skill, "currency", 2);
    Json nextPrice = nullptr;
    Json nextCurrency = nullptr;
    if (rank.is_number() && maxRank.is_number() && rank.get<double>() >= 0 &&
        rank.get<double>() < maxRank.get<double>() && rank.get<double>() < maxEntries)
    {
        const auto index = rank.get<size_t>();
        nextPrice = ForRank(costs, index);
        nextCurrency = ForRank(currencies, index);
    }

    nodes[key] = {
        {"rank", rank}, {"maxRank", maxRank}, {"unlocked", ReadField(*skill, "is_unlocked")},
        {"prices", costs}, {"currency", currencies},
        {"nextPrice", nextPrice}, {"nextCurrency", nextCurrency},
        {"needsAnyLevel", ReadField(*skill, "skills_needed_at_any_level", 2)},
        {"needsMaxLevel", ReadField(*skill, "skills_needed_at_max_level", 2)},
        {"demoLocked", ReadField(*skill, "is_locked_on_demo")}
    };
}
}

Json ReadSkillCatalog()
{
    CInstance* global = nullptr;
    if (!AurieSuccess(game->GetGlobalInstance(&global)) || !global)
        throw std::runtime_error("The native skill catalog is unavailable.");

    const auto currentRoom = CurrentRoom(global);
    Json nodes = Json::object();
    bool truncated = false;
    auto* nativeCatalog = TryMember(global, "all_skills");
    const auto nativeKind = nativeCatalog ? nativeCatalog->GetKindName() : std::string();
    if (nativeCatalog && nativeCatalog->m_Kind == VALUE_OBJECT)
    {
        game->EnumInstanceMembers(*nativeCatalog, [&](const char* key, RValue* value)
        {
            if (key)
                skillTelemetry::AddSkill(nodes, key, value, truncated);
            return !truncated;
        });
    }
    else if (nativeCatalog && nativeCatalog->m_Kind == VALUE_ARRAY)
    {
        size_t size = 0;
        if (AurieSuccess(game->GetArraySize(*nativeCatalog, size)))
        {
            truncated = size > skillTelemetry::maxNodes;
            for (size_t index = 0; index < std::min(size, skillTelemetry::maxNodes); ++index)
            {
                RValue* value = nullptr;
                if (AurieSuccess(game->GetArrayEntry(*nativeCatalog, index, value)))
                    skillTelemetry::AddSkill(nodes, {}, value, truncated);
            }
        }
    }

    size_t positions = 0;
    if (currentRoom == "rm_skill_tree")
    {
        game->InvokeWithObject(RValue("par_skill"), [&](CInstance* instance, CInstance*)
        {
            if (positions >= skillTelemetry::maxNodes)
                return;

            RValue object;
            if (!AurieSuccess(game->GetBuiltin("object_index", instance, NULL_INDEX, object)))
                return;
            const auto name = game->CallBuiltin("object_get_name", {object});
            if (name.m_Kind != VALUE_STRING)
                return;
            const auto key = name.ToString();
            skillTelemetry::AddSkill(nodes, key, TryMember(instance, "skill"), truncated);
            if (!nodes.contains(key))
                return;

            auto& node = nodes[key];
            for (const auto* property : {"x", "y", "id"})
            {
                RValue value;
                if (AurieSuccess(game->GetBuiltin(property, instance, NULL_INDEX, value)))
                    node[property] = skillTelemetry::ReadValue(&value);
            }
            node["objectIndex"] = skillTelemetry::ReadValue(&object);
            ++positions;
        });
    }

    Json result = {
        {"room", currentRoom}, {"allSkillsKind", nativeKind},
        {"positionCount", positions}, {"truncated", truncated}, {"nodes", std::move(nodes)}
    };
    for (const auto* key : {"all_skill_levels", "total_skill_levels_upgraded", "prestige_level"})
        result[key] = skillTelemetry::ReadValue(TryMember(global, key));

    return result;
}
