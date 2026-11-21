local function address(object)
    return object and type(object.IsValid) == "function" and object:IsValid() and object:GetAddress() or nil
end

local References = {}
References.__index = References
local releasedSlot

local function arrayObject(array, index)
    local object = array[index]
    if object and type(object.IsValid) ~= "function" then object = object:get() end
    return object
end

function References.new(gameplay, pawn)
    local instance = gameplay:GetGameInstance(pawn)
    local libraryClass = StaticFindObject("/Script/Engine.ObjectLibrary")
    assert(address(instance) and address(libraryClass), "engine reference owner unavailable")
    local library = StaticConstructObject(libraryClass, instance)
    local libraryAddress = assert(address(library), "could not construct the private object library")
    assert(library.Objects:GetArrayNum() == 0, "object library is not empty")
    return setmetatable({ instance = instance, library = library, libraryAddress = libraryAddress }, References)
end

function References:attach()
    local refs = self.instance.ReferencedObjects
    local count = refs:GetArrayNum()
    local slot = releasedSlot
    releasedSlot = nil
    if slot and slot.instance == address(self.instance) and slot.index <= count
        and not address(arrayObject(refs, slot.index)) then
        self.index = slot.index
    else
        self.index = count + 1
    end
    -- The only entry written in the game instance belongs to this preload.
    refs[self.index] = self.library
    assert(address(arrayObject(refs, self.index)) == self.libraryAddress, "reference owner did not round-trip")
end

function References:ownedIndex(refs)
    if not self.index then return end
    local count = refs:GetArrayNum()
    if self.index <= count and address(arrayObject(refs, self.index)) == self.libraryAddress then
        return self.index
    end
    -- Native removal of another entry can move ours.
    for index = 1, count do
        if address(arrayObject(refs, index)) == self.libraryAddress then return index end
    end
end

function References:hold(class)
    assert(self:ownedIndex(self.instance.ReferencedObjects), "reference owner is no longer held by the game")
    local objects = self.library.Objects
    local index = objects:GetArrayNum() + 1
    objects[index] = class
    assert(address(arrayObject(objects, index)) == address(class), "class reference did not round-trip")
    return index
end

function References:holds(index, expected)
    if not address(self.library) or not self:ownedIndex(self.instance.ReferencedObjects) then return false end
    local objects = self.library.Objects
    return index <= objects:GetArrayNum() and address(arrayObject(objects, index)) == expected
end

function References:release()
    local cleared, failures = 0, 0
    local ok, removed = pcall(function()
        if not address(self.library) then return 0 end
        local objects = self.library.Objects
        local count = objects:GetArrayNum()
        objects:Empty()
        assert(objects:GetArrayNum() == 0, "private strong references did not clear")
        return count
    end)
    if ok then cleared = removed else failures = failures + 1 end
    local detached = pcall(function()
        if not address(self.instance) or not self.index then return end
        local refs = self.instance.ReferencedObjects
        local index = self:ownedIndex(refs)
        if not index then return end
        refs[index] = nil
        assert(not address(arrayObject(refs, index)), "reference owner slot did not clear")
        releasedSlot = { instance = address(self.instance), index = index }
    end)
    if not detached then failures = failures + 1 end
    return cleared, detached, failures
end

return References
