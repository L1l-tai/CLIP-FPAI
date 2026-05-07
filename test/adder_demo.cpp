#include "file_utils.hpp"
#include "et_device.hpp"
#include "fps_calculator.hpp"
#include "vis_helper.hpp"
#include "icraft_utils.hpp"
// icraft includes
#include <icraft-xrt/core/session.h>
#include "compile_fpai_target.hpp"
// 3rd-party dependency includes
#include <opencv2/opencv.hpp>
#include "yaml-cpp/yaml.h"
// system libs
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <memory>
#include <condition_variable>
#include <atomic>
#include <thread>
#include <functional>
#include <filesystem>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::chrono;
using namespace std::chrono_literals;
namespace fs = std::filesystem;
using namespace fpai;


int main(int argc, char *argv[])
{
    // FPAI设备初始化
    std::string device_url = "axi://zg330aiu?npu=0x40000000&dma=0x80000000";
    auto device = Device::Open(device_url.c_str());
    auto fpai_device = device.cast<FPAIDevice>();

    // Read version register
    uint32_t reg_base = 0x400C0000;
    int version = fpai_device.defaultRegRegion().read(reg_base + 0xC0, false);
    std::cout << "Adder demo version is " << std::hex << "0x" << version << std::dec << std::endl;

    // Allocate memory for adder demo
    int num = 16;
    int byte_size = num * 64;  // allocate 64-byte for every digit
    std::shared_ptr<int8_t[]> dest = std::shared_ptr<int8_t[]>(new int8_t[byte_size]{ 0 });
    std::shared_ptr<int8_t[]> src  = std::shared_ptr<int8_t[]>(new int8_t[byte_size]{ 0 });
    auto mem_chunk = fpai_device.defaultMemRegion().malloc(byte_size * 2, 0, 64);
    uint32_t mem_addr = mem_chunk->begin.addr();
    std::cout << "Used PL-DDR address for demo is " << mem_addr << std::endl;

    // *******************************************
    // @ Prepare for input data
    // *******************************************
    for (int i = 0; i < num; i++)
        src[i * 64] = i;  // -> src is expected to be {512'd0, 512'd1, 512'd2, ...}
    mem_chunk.write(0, (char*)src.get(), byte_size);


    // *******************************************
    // @ Check data before the adder operation
    // *******************************************
    // mem_chunk.read((char*)dest.get(), 0, byte_size);  // read data with addr = (mem_addr + 0)
    // std::cout << "Print original src data..." << std::endl;
    // for (int i = 0; i < num; i++)
    //     std::cout << static_cast<int>(dest[i * 64]) << " ";
    // std::cout << std::endl;
    //
    // mem_chunk.read((char*)dest.get(), byte_size, byte_size);  // read data with addr = (mem_addr + byte_size)
    // std::cout << "Print original dst data..." << std::endl;
    // for (int i = 0; i < num; i++)
    //     std::cout << static_cast<int>(dest[i * 64]) << " ";
    // std::cout << std::endl;


    // *******************************************
    // @ Adder op configuration
    // *******************************************
    uint32_t reg0 = ((byte_size / 64) << 16) | mem_addr;               // { read size,  read base address};
    uint32_t reg1 = ((byte_size / 64) << 16) | (mem_addr + byte_size); // {write size, write base address};
    fpai_device.defaultRegRegion().write(reg_base + 0x4, reg0, false);
    fpai_device.defaultRegRegion().write(reg_base + 0x8, reg1, false);
    fpai_device.defaultRegRegion().write(reg_base + 0x0,    1, false); // start op
    // wait for done
    auto start = std::chrono::system_clock::now();
    int done = fpai_device.defaultRegRegion().read(reg_base + 0x0080, false);
    auto end = std::chrono::system_clock::now();
    int during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

    while(done == 0)
    {
        end = std::chrono::system_clock::now();
        during = (int)std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        if (during > 10000)  // wait for 10 seconds
        {
            std::cout << "Error: FPGA Time Out!" << std::endl;
            return -1;
        }
        done = fpai_device.defaultRegRegion().read(reg_base + 0x80, false);
    }

    // *******************************************
    // @ Read output data
    // *******************************************
    std::cout << "Op Done! Print processed data..." << std::endl;
    mem_chunk.read((char*)dest.get(), byte_size, byte_size);
    for (int i = 0; i < num; i++)
        std::cout << std::setw(3) << static_cast<int>(src[i * 64]) << " + 1 = " << static_cast<int>(dest[i * 64]) << std::endl;

    // std::cin.get(); // Press Enter to stop
    Device::Close(device);

    return 0;
}