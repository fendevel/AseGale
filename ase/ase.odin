package ase

import "core:math/fixed"
import "core:os"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:bytes"
import "core:compress"
import "core:compress/zlib"

Fixed :: fixed.Fixed16_16

Header_Flag :: enum {
    Has_Layer_Opacity,
}

Header :: struct #packed {
    size: u32,
    magic: u16,
    frame_count: u16,
    dim: [2]u16,
    bpp: u16,
    flags: bit_set[Header_Flag; u32],
    // deprecated
    frame_speed_ms: u16,
    _: [8]byte `fmt:"-"`,
    palette_transparent_index: u8,
    _: [3]byte `fmt:"-"`,
    palette_size: u16,
    pixel_size: [2]u8,
    grid_pos: [2]i16,
    grid_size: [2]u16,
    _: [84]byte `fmt:"-"`,
}

Frame :: struct #packed {
    size: u32,
    magic: u16,
    chunk_count: u16,
    duration: u16,
    _: [2]byte `fmt:"-"`,
    chunk_count2: u32,
}

Chunk_Type :: enum u16 {
    Old_Palette_8bit = 0x0004,
    Old_Palette_6bit = 0x0011,
    Layer = 0x2004,
    Cel = 0x2005,
    Cel_Extra = 0x2006,
    Color_Profile = 0x2007,
    External_Files = 0x2008,
    
    Mask_DEPRECATED = 0x2016,

    Path = 0x2017,
    Tags = 0x2018,
    Palette = 0x2019,
    User_Data = 0x2020,
    Slice = 0x2022,
    Tileset = 0x2023,
}


Chunk_Header :: struct #packed {
    size: u32,
    type: Chunk_Type,
}

Layer_Flag :: enum {
    Visible,
    Editable,
    Lock_Movement,
    Background,
    Linked_Cels,
    Collapsed,
    Reference,
}

Layer_Type :: enum u16 {
    Image,
    Group,
    Tilemap,
}

Layer_Blend_Mode :: enum u16 {
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    Color_Dodge,
    Color_Burn,
    Hard_Light,
    Soft_Light,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity,
    Addition,
    Subtract,
    Divide,
}

Layer :: struct #packed {
    chunk: Chunk_Header,
    flags: bit_set[Layer_Flag; u16],
    type: Layer_Type,
    child_level: u16,
    _: [4]byte `fmt:"-"`,
    blend_mode: Layer_Blend_Mode,
    opacity: u8,
    _: [3]byte `fmt:"-"`,
    name_len: u16,
}

Cel_Type :: enum u16 {
    Raw_Image_Data,
    Linked_Cel,
    Compressed_Image,
    Compressed_Tilemap,
}

Cel :: struct #packed {
    chunk: Chunk_Header,
    index: u16,
    pos: [2]i16,
    opacity: u8,
    type: Cel_Type,
    z_index: i16,
    _: [5]byte `fmt:"-"`,
}

Cel_Raw_Image :: struct #packed {
    dim: [2]u16,
}

Cel_Linked_Cel :: struct #packed {
    frame: u16,
}

Cel_Compressed_Image :: struct #packed {
    dim: [2]u16,
}

Cel_Compressed_Tilemap :: struct #packed {
    tiles: [2]u16,
    bits_per_tile: u16,
    tile_id_bitmask: u32,
    x_flip_bitmask: u32,
    y_flip_bitmask: u32,
    diagonal_flip_mask: u32,
    _: [10]byte `fmt:"-"`,
}

Cel_Extra_Flag :: enum {
    Bounds,
}

Cel_Extra :: struct #packed {
    chunk: Chunk_Header,
    flags: bit_set[Cel_Extra_Flag; u32],
    pos: [2]Fixed,
    size: [2]Fixed,
    _: [16]byte,
}

Color_Profile_Type :: enum u16 {
    None,
    sRGB,
    ICC,
}

Color_Profile_Flag :: enum {
    Gamma,
}

Color_Profile :: struct #packed {
    chunk: Chunk_Header,
    type: Color_Profile_Type,
    flags: bit_set[Color_Profile_Flag; u16],
    gamma: Fixed,
    _: [8]byte `fmt:"-"`,
}

Palette_Entry_Flag :: enum {
    Has_Name,
}

Palette_Entry :: struct #packed {
    flags: bit_set[Palette_Entry_Flag; u16],
    rgba: [4]u8,
}

Palette :: struct #packed {
    chunk: Chunk_Header,
    entry_count: u32,
    change_range: [2]u32,
    _: [8]byte `fmt:"-"`,

}

get_palette_entry_name :: proc(entry: ^Palette_Entry) -> (string, bool) {
    if .Has_Name in entry.flags {
        name_len := mem.reinterpret_copy(u16, rawptr(uintptr(entry) + size_of(Palette_Entry)))
        data := cast([^]byte)(uintptr(entry) + size_of(Palette_Entry) + size_of(u16))

        return string(data[:name_len]), true
    }

    return "", false
}

get_palette_entries :: proc(palette: ^Palette, allocator := context.temp_allocator) -> []^Palette_Entry {
    data := cast([^]byte)(uintptr(palette) + size_of(Palette))

    res := make([]^Palette_Entry, palette.entry_count)

    offset := 0

    for i in 0..<palette.entry_count {
        entry := cast(^Palette_Entry)&data[offset]

        res[i] = entry

        offset += size_of(Palette_Entry)
        if name, has_name := get_palette_entry_name(entry); has_name {
            offset += len(name)
        }
    }

    return res
}

get_layer_name :: proc(layer: ^Layer) -> string {
    name_data := rawptr(uintptr(layer) + offset_of(layer.name_len) + size_of(layer.name_len))
    return string(slice.bytes_from_ptr(name_data, int(layer.name_len)))
}

gather_frames :: proc(header: ^Header, allocator := context.allocator) -> []^Frame {
    buffer := slice.bytes_from_ptr(header, int(header.size))
    res := make([]^Frame, header.frame_count)

    frame_offset := size_of(Header)
    for i in 0..<int(header.frame_count) {
        frame := cast(^Frame)&buffer[frame_offset]
        defer frame_offset += int(frame.size)
        assert(frame.magic == 0xf1fa)

        res[i] = frame
    }

    return res
}

gather_frame_chunks :: proc(header: ^Header, frame_index: int, allocator := context.allocator) -> []^Chunk_Header {
    assert(frame_index < int(header.frame_count))

    buffer := slice.bytes_from_ptr(header, int(header.size))

    frame_offset := size_of(Header)
    for i in 0..<int(header.frame_count) {
        frame := cast(^Frame)&buffer[frame_offset]
        defer frame_offset += int(frame.size)
        assert(frame.magic == 0xf1fa)

        if i != frame_index {
            continue
        }

        chunk_offset := frame_offset + size_of(Frame)
        chunk_count := int(frame.chunk_count) if frame.chunk_count != max(u16) else int(frame.chunk_count2)

        res := make([]^Chunk_Header, chunk_count)

        for j in 0..<chunk_count {
            chunk := cast(^Chunk_Header)&buffer[chunk_offset]
            defer chunk_offset += int(chunk.size)
            res[j] = chunk
        }

        return res
    }

    return nil
}

read_cel_data :: proc(header: ^Header, cel: ^Cel, allocator := context.allocator) -> (pixels: []byte, allocated, good: bool) {
    #partial switch cel.type {
        case .Raw_Image_Data: {
            raw_image_data := cast(^Cel_Raw_Image)(uintptr(cel) + size_of(Cel))
            data := uintptr(cel) + size_of(Cel) + size_of(Cel_Raw_Image)
            size := raw_image_data.dim.x*raw_image_data.dim.y*(header.bpp/8)
            return slice.bytes_from_ptr(rawptr(data), int(size)), false, true
        }
        case .Compressed_Image: {
            compressed_image := cast(^Cel_Compressed_Image)(uintptr(cel) + size_of(Cel))
            compressed_data := uintptr(cel) + size_of(Cel) + size_of(Cel_Compressed_Image)
            size := compressed_image.dim.x*compressed_image.dim.y*(header.bpp/8)

            compressed_size := uintptr(cel.chunk.size) - (size_of(Cel) + size_of(Cel_Compressed_Image))
            input := slice.bytes_from_ptr(rawptr(compressed_data), int(compressed_size))
            output: bytes.Buffer
            bytes.buffer_init_allocator(&output, 0, int(size), allocator)

            err := zlib.inflate_from_byte_array(input, &output, expected_output_size = int(size))
            if err != nil {
                bytes.buffer_destroy(&output)
                fmt.eprintln("ERROR:", err)
                return nil, false, false
            }

            return output.buf[:], true, true
        }
    }

    return nil, false, false
}
