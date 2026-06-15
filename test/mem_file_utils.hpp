#pragma once

#include <cstdint>
#include <string>

// 读取 .mem 文件到 buffer（每行128hex = 64字节），返回实际读取字节数
int read_mem_file(const std::string& path, int8_t* buf, int max_bytes);

// 将 buffer 写入 .mem 文件（每 64 字节编码为一行 128hex）
void write_mem_file(const std::string& path, const int8_t* buf, int num_bytes);
