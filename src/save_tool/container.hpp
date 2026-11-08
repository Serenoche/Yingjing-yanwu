#pragma once
#include "win_support.hpp"
#include <set>

namespace pbz_save {
struct Entry { std::string name; unsigned char algorithm=0,flag=0;std::uint32_t raw_size=0;Bytes sealed; };
using Slots=std::vector<Entry>;
inline std::uint16_t u16(const Bytes& data,std::size_t at){
    require(at<=data.size() && data.size()-at>=2,"Truncated directory integer");
    return static_cast<std::uint16_t>(data[at]|(static_cast<std::uint16_t>(data[at+1])<<8));
}
inline std::uint32_t u32(const Bytes& data,std::size_t at){
    require(at<=data.size() && data.size()-at>=4,"Truncated directory integer");std::uint32_t result=0;
    for(unsigned int i=0;i<4;++i)result|=static_cast<std::uint32_t>(data[at+i])<<(8*i);return result;
}
inline void put16(Bytes& data,std::size_t at,std::uint16_t value){data.at(at)=static_cast<unsigned char>(value);data.at(at+1)=static_cast<unsigned char>(value>>8);}
inline void put32(Bytes& data,std::size_t at,std::uint32_t value){for(unsigned int i=0;i<4;++i)data.at(at+i)=static_cast<unsigned char>(value>>(8*i));}
inline Slots open_container(Cipher& cipher,const unsigned char* bytes,std::size_t size){
    require(size>=48 && std::memcmp(bytes,"PBZS",4)==0 && bytes[4]==3 && bytes[5]==1,"Unsupported PBZS container");
    Bytes header(bytes,bytes+12);const auto count=u16(header,6);const auto directory_size=u32(header,8);
    require(count>0 && count<=4096 && directory_size>=36 && directory_size<=8*1024*1024
        && directory_size<=size-12,"PBZS directory extent is invalid");
    const std::size_t start=12+static_cast<std::size_t>(directory_size);
    const auto directory=cipher.open(bytes+12,directory_size);
    require(directory.size()>=12 && std::equal(header.begin(),header.end(),directory.begin()),"PBZS directory echo differs");
    Slots slots;slots.reserve(count);std::set<std::string> names;std::size_t cursor=12,last=0;
    for(std::uint16_t i=0;i<count;++i){
        const auto length=u16(directory,cursor);cursor+=2;
        require(length>0 && length<=1024 && cursor<=directory.size() && directory.size()-cursor>=static_cast<std::size_t>(length)+14,"PBZS row is truncated");
        Entry entry;entry.name.assign(reinterpret_cast<const char*>(directory.data()+cursor),length);valid_utf8(entry.name);
        require(entry.name.find('\0')==std::string::npos && names.insert(entry.name).second,"PBZS slot name is duplicate or contains NUL");
        cursor+=length;entry.algorithm=directory[cursor];entry.flag=directory[cursor+1];entry.raw_size=u32(directory,cursor+2);
        const auto offset=u32(directory,cursor+6),block_size=u32(directory,cursor+10);cursor+=14;
        require(entry.algorithm<=2 && entry.raw_size>0 && offset==last && block_size>=36
            && last<=size-start && block_size<=size-start-last,"PBZS slot extent is overlapping or invalid");
        entry.sealed.assign(bytes+start+last,bytes+start+last+block_size);
        cipher.open(entry.sealed.data(),entry.sealed.size()); // Authenticate compressed bytes; never decompress them.
        last+=block_size;slots.push_back(std::move(entry));
    }
    require(cursor==directory.size() && last==size-start,"PBZS entries do not cover the container exactly");return slots;
}
inline Slots open_container(Cipher& cipher,const ReadOnlyFile& file){return open_container(cipher,file.data(),file.size());}
inline bool same_entry(const Entry& first,const Entry& second){
    return first.name==second.name && first.algorithm==second.algorithm && first.flag==second.flag
        && first.raw_size==second.raw_size && first.sealed==second.sealed;
}
inline const Entry* find(const Slots& slots,const std::string& name){
    const auto result=std::find_if(slots.begin(),slots.end(),[&](const Entry& entry){return entry.name==name;});return result==slots.end()?nullptr:&*result;
}
inline Bytes seal_container(Cipher& cipher,const Slots& slots){
    require(!slots.empty() && slots.size()<=4096,"Unsupported staged slot count");
    std::size_t table_size=12,payload_size=0;
    for(const auto& entry:slots){
        require(!entry.name.empty() && entry.name.size()<=1024 && entry.sealed.size()>=36,"Unsupported staged row");
        table_size+=entry.name.size()+16;payload_size+=entry.sealed.size();
    }
    require(table_size+36<=8*1024*1024 && payload_size<512ULL*1024*1024 && table_size+payload_size+48<=512ULL*1024*1024,"Staged save exceeds supported bounds");
    Bytes header={'P','B','Z','S',3,1,0,0,0,0,0,0};put16(header,6,static_cast<std::uint16_t>(slots.size()));
    put32(header,8,static_cast<std::uint32_t>(table_size+36));Bytes directory(table_size);std::copy(header.begin(),header.end(),directory.begin());
    std::size_t cursor=12,offset=0;
    for(const auto& entry:slots){
        put16(directory,cursor,static_cast<std::uint16_t>(entry.name.size()));cursor+=2;
        std::memcpy(directory.data()+cursor,entry.name.data(),entry.name.size());cursor+=entry.name.size();
        directory[cursor]=entry.algorithm;directory[cursor+1]=entry.flag;put32(directory,cursor+2,entry.raw_size);
        put32(directory,cursor+6,static_cast<std::uint32_t>(offset));put32(directory,cursor+10,static_cast<std::uint32_t>(entry.sealed.size()));
        cursor+=14;offset+=entry.sealed.size();
    }
    const auto sealed_directory=cipher.seal(directory);Bytes result;result.reserve(12+sealed_directory.size()+payload_size);
    result.insert(result.end(),header.begin(),header.end());result.insert(result.end(),sealed_directory.begin(),sealed_directory.end());
    for(const auto& entry:slots)result.insert(result.end(),entry.sealed.begin(),entry.sealed.end());return result;
}
inline std::string ascii_lower(std::string text){for(auto& value:text)if(value>='A' && value<='Z')value=static_cast<char>(value-'A'+'a');return text;}
inline const std::vector<std::string>& private_names(){
    static const std::vector<std::string> names={"PBZArenaIntegratedTraining","PBZArenaIntegratedCycle0","PBZArenaIntegratedCycle1",
        "PBZArenaIntegratedCycle2","PBZArenaIntegratedCycle3","PBZArenaIntegratedCycle4","PBZArenaIntegratedCycle5","PBZArenaIntegratedCycle6",
        "PBZArenaIntegratedLao","PBZArenaIntegratedLakeTraining","PBZArenaIntegratedLakeCycle0","PBZArenaIntegratedLakeCycle1",
        "PBZArenaIntegratedLakeCycle2","PBZArenaIntegratedLakeCycle3","PBZArenaIntegratedLakeCycle4","PBZArenaIntegratedLakeCycle5",
        "PBZArenaIntegratedLakeCycle6","PBZArenaIntegratedLakeLao"};return names;
}
inline const std::vector<std::string>& legacy_private_names(){
    static const std::vector<std::string> names(private_names().begin(),private_names().begin()+8);return names;
}
inline bool private_name(const std::string& name){const auto& names=private_names();return std::find(names.begin(),names.end(),name)!=names.end();}
inline void private_case_check(const Slots& slots){
    for(const auto& entry:slots){
        const auto lower=ascii_lower(entry.name);
        if(lower.rfind("pbzarenaintegrated",0)==0)require(private_name(entry.name),"Unknown or case-variant private slot namespace");
    }
}
} // namespace pbz_save
