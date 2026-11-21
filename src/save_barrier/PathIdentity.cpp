#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

namespace {
// The supported LuaMadeSimple MSVC wrappers read the Lua state at offset zero.
// Verify that calling convention before asking them to exchange Lua values.
struct LuaView { void* state; };
using GetString = std::string_view* (__cdecl*)(const LuaView*, std::string_view*, int);
using PushBool = void (__cdecl*)(const LuaView*, bool);

template <typename Function, std::size_t Size>
Function resolve(HMODULE module, const char* name, const unsigned char (&prefix)[Size]) {
    if (!module) return nullptr;
    const auto address = reinterpret_cast<std::uintptr_t>(GetProcAddress(module, name));
    if (!address || std::memcmp(reinterpret_cast<const void*>(address), prefix, Size) != 0) return nullptr;
    return reinterpret_cast<Function>(address);
}

std::wstring readPath(const LuaView& lua, GetString getString) {
    std::string_view path;
    getString(&lua, &path, -1);
    if (path.empty() || path.size() > 4096 || path.find('\0') != path.npos) return {};
    const auto size = static_cast<int>(path.size());
    const int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), size, nullptr, 0);
    if (chars <= 0) return {};
    std::wstring wide(static_cast<std::size_t>(chars), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), size, wide.data(), chars) != chars) return {};
    return wide;
}

struct FileIdentity {
    explicit FileIdentity(const std::wstring& path) : handle(path.empty() ? INVALID_HANDLE_VALUE :
        CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr)) {}
    ~FileIdentity() { if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle); }

    bool read(FILE_ID_INFO& result) const {
        return handle != INVALID_HANDLE_VALUE
            && GetFileInformationByHandleEx(handle, FileIdInfo, &result, sizeof(result)) != 0;
    }
    const HANDLE handle;
};
}

extern "C" __declspec(dllexport) int __cdecl PBZSamePath(void* state) {
    constexpr unsigned char stringWrapper[] = {0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10,
        0x57, 0x48, 0x83, 0xec, 0x20, 0x41, 0x8b, 0xd8, 0x48, 0x8b, 0xf2, 0x48, 0x8b, 0xf9,
        0x8b, 0xd3, 0x48, 0x8b, 0x09, 0x45, 0x33, 0xc0, 0xe8};
    constexpr unsigned char booleanWrapper[] = {0x48, 0x8b, 0x09, 0x0f, 0xb6, 0xd2, 0xe9};
    const auto loader = GetModuleHandleW(L"UE4SS.dll");
    const auto getString = resolve<GetString>(loader,
        "?get_string@Lua@LuaMadeSimple@RC@@QEBA?AV?$basic_string_view@DU?$char_traits@D@std@@@std@@H@Z", stringWrapper);
    const auto pushBool = resolve<PushBool>(loader, "?set_bool@Lua@LuaMadeSimple@RC@@QEBAX_N@Z", booleanWrapper);
    if (!state || !getString || !pushBool) return 0;

    LuaView lua{state};
    bool same = false;
    try {
        // get_string consumes its argument. Capture its bytes before reading the other path.
        const auto right = readPath(lua, getString);
        const auto left = readPath(lua, getString);
        const FileIdentity leftFile(left), rightFile(right);
        FILE_ID_INFO a{}, b{};
        same = leftFile.read(a) && rightFile.read(b) && a.VolumeSerialNumber == b.VolumeSerialNumber
            && std::memcmp(a.FileId.Identifier, b.FileId.Identifier, sizeof(a.FileId.Identifier)) == 0;
    } catch (...) {
        same = false;
    }
    pushBool(&lua, same);
    return 1;
}
