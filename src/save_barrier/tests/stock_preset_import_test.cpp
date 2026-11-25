#include "stock_preset_import.hpp"
#include <cstdio>
#include <map>

namespace {
int checks = 0, live = 0, parsed_calls = 0, merged_calls = 0;
bool parser_fails = false, parser_wrong_keys = false, merge_loses_formal = false;
void check(bool ok, const char* label) { if (!ok) { std::fprintf(stderr, "FAIL %s\n", label); std::exit(1); } ++checks; std::printf("PASS %s\n", label); }
struct Object { std::map<std::wstring, int> fields; };
struct Control { void* table; volatile LONG strong; LONG weak; Object* object; };
pbz_barrier::SharedJson make() {
    auto object = new Object; auto control = new Control{nullptr, 1, 1, object}; ++live; return {object, control};
}
void __fastcall release(void* pointer) {
    auto c = static_cast<Control*>(pointer);
    if (InterlockedDecrement(&c->strong) == 0) { delete c->object; delete c; --live; }
}
void* __fastcall construct(pbz_barrier::JsonWrapper* wrapper) { *wrapper = {}; wrapper->shared = make(); return wrapper; }
void __fastcall merge(void*, pbz_barrier::SharedJson* destination, const pbz_barrier::SharedJson* source) {
    ++merged_calls;
    auto dest = static_cast<Object*>(destination->object);
    for (const auto& field : static_cast<Object*>(source->object)->fields) dest->fields[field.first] = field.second;
    if (merge_loses_formal) dest->fields.erase(L"formal");
    release(destination->controller);
}
bool __fastcall parse(pbz_barrier::JsonWrapper* wrapper, const pbz_barrier::BorrowedString* text) {
    ++parsed_calls;
    check(text && text->data && text->number > 1 && text->maximum == text->number && text->data[text->number - 1] == 0,
        "native parser receives a bounded borrowed NUL-terminated FString");
    if (parser_fails) return false;
    auto object = static_cast<Object*>(wrapper->shared.object);
    const auto root = pbz_dropin::Json::parse(pbz_save::utf8(std::wstring(text->data)));
    for (auto slot = root.begin(); slot != root.end(); ++slot)
        object->fields[std::wstring(slot.key().begin(), slot.key().end())] =
            slot->at("PBZGameSystem").at("CycleCount").get<int>();
    if (parser_wrong_keys) object->fields[L"__Advanced__"] = 4;
    return true;
}
bool legacy_writes_string = false;
bool __fastcall parse_legacy(pbz_barrier::JsonWrapper* wrapper, const pbz_barrier::BorrowedJsonText* text) {
    const unsigned char empty_string[sizeof(wrapper->string)]{};
    check(!wrapper->shared.object && !wrapper->shared.controller
        && std::memcmp(wrapper->string, empty_string, sizeof(empty_string)) == 0,
        "legacy parser receives an empty wrapper");
    wrapper->shared = make();
    if (legacy_writes_string) wrapper->string[0] = 1;
    const pbz_barrier::BorrowedString reference_text{text->data, text->number, text->capacity};
    return parse(wrapper, &reference_text);
}

bool collect(void* object, std::set<std::wstring>& keys, std::string&) {
    keys.clear(); for (const auto& field : static_cast<Object*>(object)->fields) keys.insert(field.first); return true;
}
std::int32_t __fastcall remove_summary(void* map, const pbz_barrier::BorrowedString* key) {
    auto header = static_cast<unsigned char*>(map);
    unsigned char* entries = nullptr; std::int32_t number = 0, free_number = 0;
    std::memcpy(&entries, header, 8); std::memcpy(&number, header + 8, 4); std::memcpy(&free_number, header + 0x34, 4);
    auto bits = reinterpret_cast<std::uint32_t*>(header + 0x10);
    for (std::int32_t i = 0; i < number; ++i) {
        if (!(bits[i >> 5] & (1u << (i & 31)))) continue;
        pbz_barrier::BorrowedString stored{}; std::memcpy(&stored, entries + i * 0xC0, sizeof(stored));
        if (stored.number != key->number || std::wmemcmp(stored.data, key->data, static_cast<std::size_t>(key->number)) != 0) continue;
        bits[i >> 5] &= ~(1u << (i & 31)); ++free_number; std::memcpy(header + 0x34, &free_number, 4); return 1;
    }
    return 0;
}

std::string fixture() {
    auto maps = pbz_dropin::Json::object();
    for (int index = 1; index <= 60; ++index) {
        const auto slot = std::string("PBZArenaStockMap") + (index < 10 ? "0" : "") + std::to_string(index);
        maps[slot] = {{"PBZGameSystem", {{"CurrentLevelName", "level" + std::to_string(index)}}}};
    }
    auto players = pbz_dropin::Json::object();
    for (int cycle = -1; cycle <= 6; ++cycle)
        players[std::to_string(cycle)] = {{"PBZGameSystem", {{"CycleCount", (std::max)(0, cycle)}}},
            {"Inventory", {{"Marker", cycle}}}, {"AbilityNode_RenewalHun", pbz_dropin::Json::object()}};
    return pbz_dropin::Json{{"schemaVersion", 2}, {"slotCapacity", 60},
        {"shared", {{"PBZGameSystem", {{"DifficultModeByte", 3}}}}}, {"maps", maps}, {"players", players}}.dump();
}
bool prepare(const std::string& text, pbz_dropin::PreparedPresets& output, std::string& reason) {
    const auto bytes = reinterpret_cast<const unsigned char*>(text.data());
    return pbz_dropin::prepare_bytes(bytes, text.size(), pbz_save::sha256(bytes, text.size()), output, reason);
}
} // namespace

int main() {
    std::string reason; pbz_dropin::PreparedPresets presets;
    const auto text = fixture();
    check(prepare(text, presets, reason) && presets.maps.size() == 60, "sixty mapped checkpoint names fit the reserved index range");
    const auto valid = presets;
    check(!pbz_dropin::prepare_bytes(reinterpret_cast<const unsigned char*>(text.data()), text.size(), std::string(64, '0'), presets, reason),
        "changed preset bytes are rejected by their pinned hash");
    auto root = pbz_dropin::Json::parse(text); root["__Advanced__"] = pbz_dropin::Json::object();
    check(!prepare(root.dump(), presets, reason), "opaque account metadata cannot be imported from the preset bundle");
    root = pbz_dropin::Json::parse(text); root["players"].erase("6");
    check(!prepare(root.dump(), presets, reason), "missing player profile is rejected");
    root = pbz_dropin::Json::parse(text); root["maps"]["PBZArenaStockMap61"] = root["maps"]["PBZArenaStockMap01"];
    check(!prepare(root.dump(), presets, reason), "the 61st map is rejected");
    root["maps"].erase("PBZArenaStockMap01");
    check(!prepare(root.dump(), presets, reason), "out-of-range slot is rejected even with sixty map records");
    pbz_dropin::SelectedPreset selected;
    check(pbz_dropin::select_preset(valid, L"PBZArenaStockMap60", 6, selected, reason) && !selected.text.empty(),
        "last reserved slot can be selected with a separate cycle-6 profile");
    check(!pbz_dropin::select_preset(valid, L"PBZArenaStockMap60", 7, selected, reason), "invalid cycle is rejected");
    check(pbz_dropin::select_preset(valid, L"PBZArenaStockMap60", 6, selected, reason), "selected preset can be recreated");
    const auto zero = pbz_dropin::compose(valid, L"PBZArenaStockMap60", 0);
    const auto lao = pbz_dropin::compose(valid, L"PBZArenaStockMap60", -1);
    check(zero.at("PBZGameSystem").at("CurrentLevelName") == "level60"
        && zero.at("Inventory").at("Marker") == 0 && lao.at("Inventory").at("Marker") == -1,
        "same map slot supports both cycle 0 and Lao without changing the world checkpoint");

    const pbz_barrier::EngineClone engine{construct, merge, release};
    auto formal = make(); auto formal_object = static_cast<Object*>(formal.object);
    formal_object->fields[L"formal"] = 17; formal_object->fields[L"__Advanced__"] = 23;
    auto clone = make(); *static_cast<Object*>(clone.object) = *formal_object;
    const auto source_before = formal_object->fields;
    check(pbz_dropin::import_into_clone(&checks, clone, selected, engine, parse, reason, collect), "approved presets merge into a separate native master clone");
    auto fields = static_cast<Object*>(clone.object)->fields;
    check(fields.size() == 3 && fields[L"formal"] == 17 && fields[L"__Advanced__"] == 23
        && fields[L"PBZArenaStockMap60"] == 6,
        "merge preserves formal slots and account metadata while adding only the selected map slot");
    check(formal_object->fields == source_before && static_cast<Control*>(clone.controller)->strong == 1 && live == 2,
        "original master stays byte-logically unchanged and temporary native owners are balanced");
    engine.drop(clone);
    for (int failure = 0; failure < 3; ++failure) {
        clone = make(); *static_cast<Object*>(clone.object) = *formal_object;
        parser_fails = failure == 0; parser_wrong_keys = failure == 1; merge_loses_formal = failure == 2;
        check(!pbz_dropin::import_into_clone(&checks, clone, selected, engine, parse, reason, collect),
            "parser failure, wrong native namespace or post-merge key loss refuses publication");
        check(formal_object->fields == source_before && live == 2 && static_cast<Control*>(clone.controller)->strong == 1,
            "failed private import retains original master and releases the parsed temporary");
        engine.drop(clone);
    }
    parser_fails = parser_wrong_keys = merge_loses_formal = false;
    clone = make(); static_cast<Object*>(clone.object)->fields[L"PBZArenaStockUnknown"] = 1;
    const auto calls_before = parsed_calls;
    check(!pbz_dropin::import_into_clone(&checks, clone, selected, engine, parse, reason, collect) && parsed_calls == calls_before,
        "unknown private-name collision refuses before native allocation or parsing");
    engine.drop(clone); engine.drop(formal);
    check(live == 0 && merged_calls == 2, "success and all import failures leak no native owners");
    const pbz_barrier::EngineClone legacy_engine{nullptr, merge, release, parse_legacy};
    clone = make();
    auto& legacy_fields = static_cast<Object*>(clone.object)->fields;
    legacy_fields[L"formal"] = 17;
    const int before_ambiguous = parsed_calls;
    check(!pbz_dropin::import_into_clone(&checks, clone, selected, legacy_engine, parse, reason, collect)
        && parsed_calls == before_ambiguous, "legacy and reference parser pointers cannot be mixed");
    legacy_writes_string = true;
    check(!pbz_dropin::import_into_clone(&checks, clone, selected, legacy_engine, nullptr, reason, collect)
        && legacy_fields.size() == 1 && live == 1, "legacy wrapper mutation is refused and cleaned up");
    legacy_writes_string = false;
    check(pbz_dropin::import_into_clone(&checks, clone, selected, legacy_engine, nullptr, reason, collect)
        && legacy_fields.size() == 2 && legacy_fields.at(L"formal") == 17
        && legacy_fields.at(L"PBZArenaStockMap60") == 6, "legacy parser imports the selected private slot");
    legacy_engine.drop(clone);
    check(live == 0, "dual parser validation releases all temporary owners");

    alignas(8) unsigned char map[0x60]{};
    std::vector<unsigned char> entries(2 * 0xC0); auto data = entries.data();
    const auto private_name = std::wstring(L"PBZArenaStockMap60");
    const pbz_barrier::BorrowedString formal_key{L"AutoSave0", 10, 10},
        private_key{private_name.c_str(), static_cast<std::int32_t>(private_name.size() + 1), static_cast<std::int32_t>(private_name.size() + 1)};
    std::memcpy(entries.data(), &formal_key, sizeof(formal_key));
    std::memcpy(entries.data() + 0xC0, &private_key, sizeof(private_key));
    const std::int32_t two = 2; const std::uint32_t both_bits = 3;
    std::memcpy(map, &data, 8); std::memcpy(map + 8, &two, 4); std::memcpy(map + 12, &two, 4);
    std::memcpy(map + 0x28, &two, 4); std::memcpy(map + 0x10, &both_bits, 4);
    check(pbz_dropin::invalidate_private_summaries(map, remove_summary, reason), "import invalidates stale private summaries through the native remover");
    std::vector<std::wstring> remaining;
    check(pbz_barrier::collect_summary_keys(map, remaining, reason) && remaining == std::vector<std::wstring>{L"AutoSave0"},
        "private summary invalidation preserves the existing formal summary and ready-state owner");
    check(pbz_dropin::invalidate_private_summaries(map, remove_summary, reason), "private summary invalidation is idempotent");
    std::printf("PASS %d isolated preset-import checks; no game launched or save read\n", checks);
    return 0;
}
