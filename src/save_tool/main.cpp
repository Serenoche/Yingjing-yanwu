#include "container.hpp"
#include "vendor/json.hpp"
#include "build_config.hpp"
#include <map>
#include <set>

namespace {
using namespace pbz_save;
using Json=nlohmann::ordered_json;
constexpr const char* owner="PBZTestArena.IntegratedMenu";
constexpr const char* reference_game_sha="4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423";
constexpr const char* presets_sha=pbz_build::presets_sha;
constexpr const char* legacy_presets_sha=pbz_build::legacy_presets_sha;

Json fingerprint(const Entry& entry){return {{"sha256",sha256(entry.sealed)},{"algorithm",entry.algorithm},
    {"flag",entry.flag},{"rawSize",entry.raw_size},{"sealedSize",entry.sealed.size()}};}
Json fingerprints(const Slots& slots){Json output=Json::object();for(const auto& entry:slots)output[entry.name]=fingerprint(entry);return output;}
bool sha_digest(const std::string& text){return text.size()==64 && text.find_first_not_of("0123456789abcdef")==std::string::npos;}
bool matches(const Entry& entry,const Json& expected){
    if(!expected.is_object() || !expected.contains("sha256") || !expected["sha256"].is_string())return false;
    for(const auto* key:{"algorithm","flag","rawSize","sealedSize"})if(!expected.contains(key) || !expected[key].is_number_unsigned())return false;
    const auto digest=expected["sha256"].get<std::string>();
    return digest.size()==64 && digest.find_first_not_of("0123456789abcdef")==std::string::npos && sha256(entry.sealed)==digest
        && expected["algorithm"].get<std::uint64_t>()==entry.algorithm && expected["flag"].get<std::uint64_t>()==entry.flag
        && expected["rawSize"].get<std::uint64_t>()==entry.raw_size && expected["sealedSize"].get<std::uint64_t>()==entry.sealed.size();
}
Json parse_manifest(const ReadOnlyFile& input){
    require(input.size()<=2*1024*1024,"Ownership manifest is too large");std::vector<std::set<std::string>> key_sets;
    const auto callback=[&](int depth,Json::parse_event_t event,Json& parsed){
        require(depth<=32,"Ownership JSON nesting is too deep");
        if(event==Json::parse_event_t::object_start)key_sets.emplace_back();
        else if(event==Json::parse_event_t::object_end){require(!key_sets.empty(),"Invalid JSON object nesting");key_sets.pop_back();}
        else if(event==Json::parse_event_t::key){require(!key_sets.empty(),"Invalid JSON key nesting");
            require(key_sets.back().insert(parsed.get<std::string>()).second,"Ownership manifest has duplicate JSON keys");}
        return true;
    };
    const auto result=Json::parse(input.data(),input.data()+input.size(),callback);
    require(result.is_object() && result.value("schemaVersion",0)==1 && result.value("owner",std::string())==owner
        && result.value("operation",std::string())=="stage" && sha_digest(result.value("gameSha256",std::string())),
        "Unsupported ownership manifest identity");
    require(result.contains("privateSlots") && result["privateSlots"].is_object()
        && (result["privateSlots"].size()==private_names().size() || result["privateSlots"].size()==legacy_private_names().size()),
        "Ownership manifest must contain the complete current or legacy private namespace");
    const bool legacy=result["privateSlots"].size()==legacy_private_names().size();
    if(legacy)require(pbz_build::legacy_presets_enabled
        && result.value("presetsSha256",std::string())==legacy_presets_sha,"Legacy ownership does not identify this build's approved eight-slot bundle");
    for(const auto& name:legacy?legacy_private_names():private_names())
        require(result["privateSlots"].contains(name),"Ownership manifest cannot claim other slots");
    return result;
}

Slots expected_stage(const Slots& source,const Slots& presets,const Json* prior){
    private_case_check(source);
    const auto advanced=find(source,"__Advanced__");require(advanced!=nullptr,"Source master has no account metadata block");
    std::size_t existing_private=0;
    for(const auto& entry:source)if(private_name(entry.name))++existing_private;
    if(prior){
        require(existing_private==(*prior)["privateSlots"].size(),"Owned private slot set is incomplete");
        const auto& owned_names=existing_private==legacy_private_names().size()?legacy_private_names():private_names();
        for(const auto& name:owned_names){
            const auto entry=find(source,name);require(entry && matches(*entry,(*prior)["privateSlots"][name]),
                "A private slot differs from its ownership manifest");
        }
    }else if(existing_private){
        require(existing_private==private_names().size(),"Partial or legacy private namespace requires its valid ownership receipt");
        for(const auto& entry:presets){const auto existing=find(source,entry.name);
            require(existing && same_entry(*existing,entry),"An unowned private-name collision is present");}
    }
    Slots expected;expected.reserve(source.size()+private_names().size()-existing_private);
    for(const auto& entry:source)if(!private_name(entry.name))expected.push_back(entry);
    expected.insert(expected.end(),presets.begin(),presets.end());return expected;
}

void verify_slots(const Slots& before,const Slots& candidate,const Slots& expected){
    require(candidate.size()==expected.size(),"Candidate slot count differs from the expected namespace");
    for(std::size_t i=0;i<expected.size();++i)require(same_entry(expected[i],candidate[i]),"Candidate changed a block, metadata or slot order");
    const auto original_advanced=find(before,"__Advanced__"),new_advanced=find(candidate,"__Advanced__");
    require(original_advanced && new_advanced && same_entry(*original_advanced,*new_advanced),"Candidate changed opaque account metadata");
}

std::wstring staging_root(){
    const auto tools=parent_path(module_path());const auto integrated=parent_path(tools);
    require(equal_path(filename(tools),L"Tools") && equal_path(filename(integrated),L"IntegratedMenu"),
        "This helper must be installed under IntegratedMenu/Tools");
    ordinary_path(integrated);return integrated+L"\\Staging";
}
std::wstring new_output(const std::wstring& argument,const std::wstring& root){
    const auto output=full_path(argument);const auto name=filename(output);
    require(name.size()>4 && equal_path(name.substr(name.size()-4),L".sav") && below(root,output),
        "Output must be a new .sav below this package's IntegratedMenu/Staging");
    ordinary_path(parent_path(output));require(!exists(output) && !exists(output+L".manifest.json"),"Output or ownership sidecar already exists");return output;
}

struct Arguments{std::wstring operation;std::map<std::wstring,std::wstring> options;};
Arguments arguments(int count,wchar_t** values){
    require(count>=2,"Usage: PBZSaveTool stage/verify --game ... --source/--before ... --presets ... --output/--after ... [--prior ...]");
    Arguments result;result.operation=values[1];require(result.operation==L"stage" || result.operation==L"verify","Only stage and verify are supported; uninstall retains dedicated saves");
    for(int i=2;i<count;i+=2){require(i+1<count,"Missing option value");const std::wstring key=values[i];
        require(key==L"--game" || key==L"--source" || key==L"--presets" || key==L"--output" || key==L"--before"
            || key==L"--after" || key==L"--prior","Unknown command option");
        require(!std::wstring(values[i+1]).empty() && result.options.emplace(key,values[i+1]).second,"Duplicate or empty command option");}
    const auto required=result.operation==L"stage"?std::vector<std::wstring>{L"--game",L"--source",L"--presets",L"--output"}
        :std::vector<std::wstring>{L"--game",L"--before",L"--presets",L"--after"};
    for(const auto& key:required)require(result.options.count(key)==1,"Required command option is missing");
    require(result.options.size()==required.size()+(result.options.count(L"--prior")?1:0),"Options belong to the other operation");return result;
}

Json run(const Arguments& command){
    const auto output_root=staging_root();
    ReadOnlyFile game(command.options.at(L"--game"),2ULL*1024*1024*1024);
    game_image(game);
    const auto actual_game_sha=sha256(game);
    // File identity is diagnostic only. The actual key material and every
    // authenticated container block determine whether this operation can run.
    auto key=game_key(game);Cipher cipher(key);SecureZeroMemory(key.data(),key.size());
    const auto source_argument=command.options.at(command.operation==L"stage"?L"--source":L"--before");
    ReadOnlyFile source(source_argument),presets_file(command.options.at(L"--presets"));
    require(!equal_path(source.path,presets_file.path) && !equal_path(source.path,game.path),"Inputs must be distinct files");
    require(sha256(presets_file)==presets_sha,"Private presets do not match the pinned shipped bundle");
    const auto original=open_container(cipher,source),presets=open_container(cipher,presets_file);
    require(presets.size()==private_names().size(),"Preset bundle must contain only the eighteen private blocks");
    for(std::size_t i=0;i<presets.size();++i)require(presets[i].name==private_names()[i],"Preset bundle contains unexpected slot names or order");
    Json prior;const Json* prior_pointer=nullptr;
    if(command.options.count(L"--prior")){ReadOnlyFile previous(command.options.at(L"--prior"),2*1024*1024);prior=parse_manifest(previous);prior_pointer=&prior;}
    const auto expected=expected_stage(original,presets,prior_pointer);
    Bytes candidate_bytes;std::wstring candidate_path;
    if(command.operation==L"stage"){
        candidate_path=new_output(command.options.at(L"--output"),output_root);
        require(!equal_path(candidate_path,source.path) && !equal_path(candidate_path,game.path)
            && !equal_path(candidate_path,presets_file.path),"Output aliases an input");
        candidate_bytes=seal_container(cipher,expected);
    }else{
        ReadOnlyFile candidate(command.options.at(L"--after"));candidate_path=candidate.path;
        require(!equal_path(candidate.path,source.path),"Verification compares two distinct files");candidate_bytes=candidate.bytes();
    }
    const auto candidate=open_container(cipher,candidate_bytes.data(),candidate_bytes.size());verify_slots(original,candidate,expected);
    Slots ordinary;for(const auto& entry:original)if(!private_name(entry.name))ordinary.push_back(entry);
    const auto advanced=find(original,"__Advanced__");require(advanced!=nullptr,"Account metadata is absent");
    Json report={{"schemaVersion",1},{"owner",owner},{"operation",command.operation==L"stage"?"stage":"verify"},
        {"gameSha256",actual_game_sha},{"referenceGameMatch",actual_game_sha==reference_game_sha},
        {"saveCompatibility","key-material-and-authenticated-container"},{"presetsSha256",presets_sha},{"sourcePath",utf8(source.path)},
        {"sourceSha256",sha256(source)},{"outputPath",utf8(candidate_path)},{"outputSha256",sha256(candidate_bytes)},
        {"originalBlockIdentity",true},{"advancedSha256Before",sha256(advanced->sealed)},{"advancedSha256After",sha256(find(candidate,"__Advanced__")->sealed)},
        {"continue",{{"changed",false},{"verification","opaque-Advanced-block-identical"}}},
        {"privateSlots",fingerprints(presets)},{"originalSlots",fingerprints(ordinary)},
        {"trainingSlot","PBZArenaIntegratedTraining"},{"cyclePrefix","PBZArenaIntegratedCycle"},
        {"originalSlotCount",ordinary.size()},{"gameStarted",false},{"runtimeDependencies",Json::array({"Windows CNG"})}};
    if(command.operation==L"stage"){
        write_exclusive(candidate_path,candidate_bytes.data(),candidate_bytes.size());
        ReadOnlyFile readback(candidate_path);require(sha256(readback)==report["outputSha256"].get<std::string>(),"Staged output readback differs");
        const auto manifest=report.dump(2,' ',true)+"\n";
        write_exclusive(candidate_path+L".manifest.json",reinterpret_cast<const unsigned char*>(manifest.data()),manifest.size());
    }
    return report;
}
void print(HANDLE handle,const std::string& text){DWORD written=0;WriteFile(handle,text.data(),static_cast<DWORD>(text.size()),&written,nullptr);}
} // namespace

int wmain(int count,wchar_t** values){
    try{const auto report=run(arguments(count,values));print(GetStdHandle(STD_OUTPUT_HANDLE),report.dump(-1,' ',true)+"\n");return 0;}
    catch(const std::exception& error){print(GetStdHandle(STD_ERROR_HANDLE),Json({{"error",error.what()},{"gameStarted",false}}).dump(-1,' ',true)+"\n");return 1;}
}
