#include "mem_file_utils.hpp"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iomanip>

int read_mem_file(const std::string& path, int8_t* buf, int max_bytes) {
    std::ifstream file(path);
    if (!file.is_open()) {
        std::cerr << "ERROR: Cannot open " << path << std::endl;
        return -1;
    }
    int total = 0;
    int line_no = 0;
    std::string line;
    while (std::getline(file, line) && total < max_bytes) {
        line_no++;
        while (!line.empty() && line.back() == '\r')
            line.pop_back();
        if (line.empty()) continue;

        int line_len = (int)line.length();
        int pairs = line_len / 2;
        int bytes_this_line = (pairs < 64) ? pairs : 64;

        // .mem 文件是 big-endian (左=MSB=高地址字节), AXI 是 little-endian
        // (低地址=LSB). 需要反转: hex[0:1] → buf[63], hex[126:127] → buf[0]
        for (int i = 0; i < bytes_this_line && total < max_bytes; i++) {
            int hex_pos = (bytes_this_line - 1 - i) * 2;
            unsigned int byte_val = 0;
            std::sscanf(line.c_str() + hex_pos, "%02x", &byte_val);
            buf[total++] = (int8_t)byte_val;
        }
    }
    std::cout << "  Loaded " << total << " bytes (" << line_no << " lines) from " << path << std::endl;
    std::cout << "  First 16 bytes: ";
    for (int i = 0; i < 16 && i < total; i++) {
        printf("%02x ", (uint8_t)buf[i]);
    }
    std::cout << std::endl;
    return total;
}

void write_mem_file(const std::string& path, const int8_t* buf, int num_bytes) {
    std::ofstream file(path);
    if (!file.is_open()) {
        std::cerr << "ERROR: Cannot write " << path << std::endl;
        return;
    }
    file << std::hex << std::setfill('0');
    int blocks = (num_bytes + 63) / 64;
    for (int b = 0; b < blocks; b++) {
        int start = b * 64;
        int remain = num_bytes - start;
        int len = (remain < 64) ? remain : 64;
        // .mem 是 big-endian: 高地址字节(=buf[len-1])写为左端 hex
        // buf[63] → hex[0:1], ..., buf[0] → hex[126:127]
        for (int i = len - 1; i >= 0; i--) {
            file << std::setw(2) << (unsigned int)(uint8_t)buf[start + i];
        }
        for (int i = len; i < 64; i++) {
            file << "00";
        }
        file << std::endl;
    }
    std::cout << "  Wrote " << num_bytes << " bytes (" << blocks
              << " blocks) to " << path << std::endl;
}
