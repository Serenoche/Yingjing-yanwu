local Async = {}
local nextUUID = 0x50425D00

function Async.request(pawn, path)
    local loader = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    assert(loader and loader:IsValid() and loader.MakeSoftClassPath and loader.Conv_SoftClassPathToSoftClassRef
        and loader.Conv_SoftClassReferenceToString and loader.LoadAssetClass, "native async class loader unavailable")
    local reference = loader:Conv_SoftClassPathToSoftClassRef(loader:MakeSoftClassPath(path))
    local text = loader:Conv_SoftClassReferenceToString(reference)
    if type(text) ~= "string" then text = text:ToString() end
    assert(text == path, "soft class path did not round-trip")

    nextUUID = nextUUID + 1
    local latent = { Linkage = -1, UUID = nextUUID, ExecutionFunction = FName("None"), CallbackTarget = pawn }
    loader:LoadAssetClass(pawn, reference, nil, latent)
end

return Async
