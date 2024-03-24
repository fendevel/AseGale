package asegale

import "base:runtime"
import "core:reflect"
import "core:os"
import "core:mem"
import "core:io"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:zlib"
import "core:path/filepath"
import "gale"
import "ase"

Options :: struct {
    output_dir: string,
}

write_palette :: proc(ostream: io.Stream, palette: [][3]byte, trans_index: int) -> (offset: int, err: io.Error) {
    palette_data: [0x100]ase.Palette_Entry

    for rgb, i in palette {
        if i == trans_index {
            continue
        }
        palette_data[i].rgba.rgb = rgb
        palette_data[i].rgba.a = 255
    }

    offset += io.write(ostream, mem.any_to_bytes(ase.Palette {
        chunk = {
            size = size_of(ase.Palette) + size_of(ase.Palette_Entry)*u32(len(palette)),
            type = .Palette,
        },
        entry_count = u32(len(palette)),
        change_range = {0, u32(len(palette)) - 1, },
    })) or_return

    offset += io.write(ostream, mem.slice_to_bytes(palette_data[:len(palette)])) or_return

    return
}

convert_gal :: proc(uri: string, options: Options) -> (native_err: os.Errno, err: io.Error) {
    if buffer, good := os.read_entire_file(uri, context.temp_allocator); good {
        if file, good := gale.parse_buffer(buffer); good {

            output_uri := filepath.join({ options.output_dir, fmt.tprintf("{}.aseprite", filepath.short_stem(uri)), }, context.temp_allocator)

            ofile, open_err := os.open(output_uri, os.O_CREATE|os.O_TRUNC)
            if open_err != 0 {
                return open_err, .Unknown
            }

            header := ase.Header {
                size = 0,
                magic = 0xa5e0,
                frame_count = u16(len(file.frames)),
                dim = {
                    u16(file.width),
                    u16(file.height),
                },
                bpp = 0,
                flags = nil,
                palette_transparent_index = 0,
                palette_size = 0,
                pixel_size = 1,
                grid_pos = 0,
                grid_size = 0,
            }

            
            ostream := os.stream_from_handle(ofile)
            io.seek(ostream, size_of(ase.Header), .Start) or_return

            offset := size_of(ase.Header)

            switch file.bpp {
                case 1: {
                    header.bpp = 8
                    header.palette_size = 2
                }
                case 4: {
                    header.bpp = 8
                    header.palette_size = 16
                }
                case 8: {
                    header.bpp = 8
                    header.palette_size = 256
                }
                case 15: fallthrough
                case 16: fallthrough
                case 24: {
                    header.bpp = 32
                    header.palette_size = 1
                }
            }

            Global_Layer :: struct {
                name: string,
                frame_layers: [dynamic]^gale.Layer,
            }

            // the frames contained in any given frame are unique to that frame but Aseprite likes to have all the layers listed under the first frame chunk
            global_layers := make([dynamic]Global_Layer, 0, 0x100, allocator = context.temp_allocator)

            for &srcframe in file.frames {
                layer_loop: for &srclayer in srcframe.layers {

                    for &gl in global_layers do if gl.name == srclayer.name {
                        append(&gl.frame_layers, &srclayer)
                        continue layer_loop
                    }

                    global_layer := Global_Layer {
                        name = srclayer.name,
                        frame_layers = make([dynamic]^gale.Layer, 0, 0x100, context.temp_allocator),
                    }
                    append(&global_layer.frame_layers, &srclayer)
                    append(&global_layers, global_layer)
                }
            }

            for &srcframe, i in file.frames {
                frame_offset := offset

                dstframe := ase.Frame {
                    size = size_of(ase.Frame),
                    magic = 0xf1fa,
                    chunk_count = 0,
                    duration = u16(srcframe.delay/time.Millisecond),
                    chunk_count2 = 0,
                }

                offset += size_of(ase.Frame)
                io.seek(ostream, i64(offset), .Start) or_return

                if i == 0 {
                    dstframe.chunk_count = 2 + u16(len(global_layers)) + u16(len(srcframe.layers))

                    offset += io.write(ostream, mem.any_to_bytes(ase.Color_Profile {
                        chunk = {
                            size = size_of(ase.Color_Profile),
                            type = .Color_Profile,
                        },
                        type = .sRGB,
                    }), nil) or_return

                    if file.bpp <= 8 {
                        offset += write_palette(ostream, srcframe.palette, srcframe.trans_color) or_return
                    } else {
                        offset += write_palette(ostream, { {}, }, -1) or_return
                    }

                } else {
                    dstframe.chunk_count = u16(len(srcframe.layers))

                    if header.bpp == 8 && mem.compare_ptrs(&srcframe.palette[0], &file.frames[i - 1].palette[0], int(header.palette_size)*3) != 0 {
                        dstframe.chunk_count += 1
                        offset += write_palette(ostream, srcframe.palette, srcframe.trans_color) or_return
                    }
                }

                dstframe.chunk_count2 = u32(dstframe.chunk_count)

                header.palette_transparent_index = u8(srcframe.trans_color)

                if i == 0 {
                    for global_layer in global_layers {

                        dstlayer := ase.Layer {
                            chunk = {
                                size = size_of(ase.Layer) + u32(len(global_layer.name)),
                                type = .Layer,
                            },
                            flags = { .Editable },
                            type = .Image,
                            child_level = 0,
                            blend_mode = .Normal,
                            opacity = 255,
                            name_len = u16(len(global_layer.name)),
                        }

                        if global_layer.frame_layers[0].visible {
                            dstlayer.flags += { .Visible }
                        }
    
                        offset += io.write(ostream, mem.any_to_bytes(dstlayer)) or_return
                        offset += io.write_string(ostream, global_layer.name) or_return
                    }
                }

                for &srclayer, j in srcframe.layers {

                    global_index := -1
                    index_in_frame := -1

                    for gl, i in global_layers do if gl.name == srclayer.name {
                        global_index = i

                        for fl, j in gl.frame_layers do if fl == &srclayer {
                            index_in_frame = j
                            break
                        }
                        break
                    }

                    assert(global_index != -1)

                    if index_in_frame != 0 && mem.compare_ptrs(&srclayer.data[0], &global_layers[global_index].frame_layers[index_in_frame - 1].data[0], len(srclayer.data)) == 0{
                        offset += io.write(ostream, mem.any_to_bytes(ase.Cel {
                            chunk = {
                                size = size_of(ase.Cel) + size_of(ase.Cel_Linked_Cel),
                                type = .Cel,
                            },
                            index = u16(global_index),
                            pos = 0,
                            opacity = srclayer.alpha,
                            type = .Linked_Cel,
                            z_index = 0,
                        })) or_return
    
                        offset += io.write(ostream, mem.any_to_bytes(ase.Cel_Linked_Cel {
                            frame = u16(i - 1),
                        })) or_return
                        continue    
                    }

                    pitch := len(srclayer.data)/int(srcframe.height)
                    alpha_pitch := len(srclayer.alpha_data)/int(srcframe.height)
                    uncompressed_data := make([]byte, srcframe.width*srcframe.height*int(header.bpp/8), context.temp_allocator)
                    
                    switch file.bpp {
                        case 1: {
                            for y in 0..<srcframe.height {
                                for x in 0..<srcframe.width {
                                    src := y*pitch + x/8
                                    dst := y*srcframe.width + x
                                    index := (srclayer.data[src] >> uint(x % 8)) & 1
                                    if int(index) == srclayer.trans_color {
                                        uncompressed_data[dst] = header.palette_transparent_index
                                    } else {
                                        uncompressed_data[dst] = index
                                    }
                                }
                            }
                        }
                        case 4: {
                            for y in 0..<srcframe.height {
                                for x in 0..<srcframe.width {
                                    src := y*pitch + x/2
                                    dst := y*srcframe.width + x

                                    index := (srclayer.data[src] >> (0 if x % 2 == 1 else 4)) & 15
                                    if int(index) == srclayer.trans_color {
                                        uncompressed_data[dst] = header.palette_transparent_index
                                    } else {
                                        uncompressed_data[dst] = index
                                    }
                                }
                            }
                        }
                        case 8: {
                            for y in 0..<srcframe.height {
                                for x in 0..<srcframe.width {
                                    src := y*pitch + x
                                    dst := y*srcframe.width + x

                                    index := srclayer.data[src]
                                    if int(index) == srclayer.trans_color {
                                        uncompressed_data[dst] = header.palette_transparent_index
                                    } else {
                                        uncompressed_data[dst] = index
                                    }
                                }
                            }
                        }
                        case 15: {
                            for y in 0..<int(srcframe.height) {
                                for x in 0..<int(srcframe.width) {
                                    src := y*pitch + x*2
                                    asrc := y*alpha_pitch + x
                                    dst := (y*int(srcframe.width) + x)*4
                                    
                                    if  mem.compare_ptrs(&srclayer.data[src], &srcframe.trans_color, 2) == 0 ||
                                        mem.compare_ptrs(&srclayer.data[src], &srclayer.trans_color, 2) == 0 {
                                        continue
                                    }

                                    rgb15 := mem.reinterpret_copy(u16, &srclayer.data[src])

                                    uncompressed_data[dst + 0] = u8((uint(((rgb15 >> 10) & 31)) * 255 + 15) / 31)
                                    uncompressed_data[dst + 1] = u8(((uint((rgb15) >> 5) & 31) * 255 + 15) / 31)
                                    uncompressed_data[dst + 2] = u8(((uint((rgb15) >> 0) & 31) * 255 + 15) / 31)
                                    uncompressed_data[dst + 3] = srclayer.alpha_data[asrc] if srclayer.alpha_on else 255
                                }
                            }
                        }
                        case 16: {
                            for y in 0..<int(srcframe.height) {
                                for x in 0..<int(srcframe.width) {
                                    src := y*pitch + x*2
                                    asrc := y*alpha_pitch + x
                                    dst := (y*int(srcframe.width) + x)*4
                                    
                                    if  mem.compare_ptrs(&srclayer.data[src], &srcframe.trans_color, 2) == 0 ||
                                        mem.compare_ptrs(&srclayer.data[src], &srclayer.trans_color, 2) == 0 {
                                        continue
                                    }

                                    rgb16 := mem.reinterpret_copy(u16, &srclayer.data[src])

                                    uncompressed_data[dst + 0] = u8((uint(((rgb16 >> 11) & 31)) * 255 + 15) / 31)
                                    uncompressed_data[dst + 1] = u8(((uint((rgb16) >> 5) & 63) * 255 + 31) / 63)
                                    uncompressed_data[dst + 2] = u8(((uint((rgb16) >> 0) & 31) * 255 + 15) / 31)
                                    uncompressed_data[dst + 3] = srclayer.alpha_data[asrc] if srclayer.alpha_on else 255
                                }
                            }
                        }
                        case 24: {
                            for y in 0..<int(srcframe.height) {
                                for x in 0..<int(srcframe.width) {
                                    src := y*pitch + x*3
                                    asrc := y*alpha_pitch + x
                                    dst := (y*int(srcframe.width) + x)*4
                                    
                                    if  mem.compare_ptrs(&srclayer.data[src], &srcframe.trans_color, 3) == 0 ||
                                        mem.compare_ptrs(&srclayer.data[src], &srclayer.trans_color, 3) == 0 {
                                        continue
                                    }

                                    uncompressed_data[dst + 0] = srclayer.data[src + 2]
                                    uncompressed_data[dst + 1] = srclayer.data[src + 1]
                                    uncompressed_data[dst + 2] = srclayer.data[src + 0]
                                    uncompressed_data[dst + 3] = srclayer.alpha_data[asrc] if srclayer.alpha_on else 255
                                }    
                            }
                        }
                    }

                    compressed_data := make([]byte, len(uncompressed_data), context.temp_allocator)
                    compressed_data_size := zlib.uLongf(len(compressed_data))
                    zlib.compress(&compressed_data[0], &compressed_data_size, &uncompressed_data[0],  zlib.uLongf(len(uncompressed_data)))
                    compressed_data = compressed_data[:compressed_data_size]

                    offset += io.write(ostream, mem.any_to_bytes(ase.Cel {
                        chunk = {
                            size = size_of(ase.Cel) + size_of(ase.Cel_Compressed_Image) + u32(len(compressed_data)),
                            type = .Cel,
                        },
                        index = u16(global_index),
                        pos = 0,
                        opacity = srclayer.alpha,
                        type = .Compressed_Image,
                        z_index = 0,
                    })) or_return

                    offset += io.write(ostream, mem.any_to_bytes(ase.Cel_Compressed_Image {
                        dim = {
                            u16(srcframe.width),
                            u16(srcframe.height),
                        },
                    })) or_return

                    offset += io.write(ostream, compressed_data) or_return
                }

                dstframe.size = u32(offset - frame_offset)

                w := io.to_writer_at(ostream)
                io.write_at(w, mem.any_to_bytes(dstframe), i64(frame_offset)) or_return
            }

            if size, err := io.size(ostream); err == nil {
                header.size = u32(size)
            }

            header.frame_count = u16(len(file.frames))

            io.seek(ostream, 0, .Start) or_return
            io.write(ostream, mem.any_to_bytes(header)) or_return

            io.close(ostream)  or_return
        }
    }

    return
}

main :: proc() {
    args := os.args[1:]

    uris := make([dynamic]string, 0, len(args), context.temp_allocator)

    options := Options {
        output_dir = filepath.dir(os.args[0]),
    }

    fmt.println("AseGale version 1.0.0")

    skip_next: bool
    for arg, i in args {
        if skip_next {
            skip_next = false
            continue
        }

        if filepath.ext(arg) == ".gal" {
            if os.exists(arg) {
                append(&uris, arg)
            } else {
                fmt.eprintfln("ERROR: Cannot find file \"{}\"", arg)
            }
        } else {
            switch arg {
                case "-o": {
                    skip_next = true
                    if i + 1 != len(args) {
                        options.output_dir = filepath.clean(args[i + 1], context.temp_allocator)
                        if !os.exists(options.output_dir) {
                            fmt.eprintfln("ERROR: the specified output directory doesn't exist: \"{}\"", options.output_dir)
                            return
                        }
                    }
                }
                case: {
                    fmt.printfln("ignoring unknown option: \"{}\"", arg)
                }
            }
        }
    }

    if slice.is_empty(uris[:]) {
        fmt.println("No input files.")
        return
    }

    successes := 0

    for uri in uris {
        fmt.printfln("file: {}", uri)

        native_err, err := convert_gal(uri, options)
        if err == nil {
            successes += 1
        } else {
            if native_err != 0 {
                fmt.eprintfln("ERROR: {}", native_err)
            } else {
                fmt.eprintfln("ERROR: {}", err)
            }
        }
    }

    if successes == len(uris) {
        fmt.printfln("{} out of {} files were successfully converted.", successes, len(uris))
    }
}