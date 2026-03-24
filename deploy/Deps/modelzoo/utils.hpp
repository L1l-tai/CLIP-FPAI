#pragma once
#include <iostream>
#include <fstream>
#include <filesystem>
#include <regex>

//-------------------- static func ----------------------------//

static std::vector<std::string> toVector(const std::string& txt_path) {
    std::vector<std::string> str_vec;
    std::ifstream iFile(txt_path);
    std::string tmp;
    if (!iFile.is_open()) {
        std::string error_ = "***error: " + txt_path + " does not exist***";
        std::cout << error_ << std::endl;
        exit(EXIT_FAILURE);
    }
    while (std::getline(iFile, tmp)) {
        tmp.erase(std::find_if(tmp.rbegin(), tmp.rend(), [](int ch) {
            return !std::isspace(ch);
            }).base(), tmp.end());
        str_vec.push_back(tmp);
    }
    iFile.close();
    return str_vec;
}

 static void checkDir(const std::string path) {
    if (!std::filesystem::exists(path)) {
        std::filesystem::create_directory(path);
        std::cout << "\n" << path << "is not exist, create new one !" << std::endl;
    }
}

 static std::string getFilename(const std::string& img_path) {
    std::regex reg(R"((/|\\|^)([^\\/:\*\?"<>\|]+)\.([\w]*)$)");
    std::smatch sm;
    std::regex_search(img_path, sm, reg);
    std::string img_name = std::string(sm[2]);
    return img_name;
}


 static void progress(int index, int total ) {
     int bar_length = 25;
     std::cout << "\r" << index + 1 << "/" << total << " [";
     for (int i = 0; i < bar_length; ++i) {
         int prog = float(index + 1) / float(total) * float(bar_length);
         if (i < prog)
             std::cout << "=";
         if (i == prog)
             std::cout << ">";
         if (i > prog)
             std::cout << " ";
     }
     std::cout << "] " << float(index + 1) / float(total) * 100.0 << "%" << std::flush;
 }

 inline float cal_distance(float x1, float y1, float x2, float y2)
 {
     return abs(x2 - x1) + abs(y2 - y1);
 };

 template<typename T>
 inline T abs_mean(T a1, T a2) {
     return abs((a1 + a2) / 2);
 }


 template<typename T>
 inline float cal_dis(T x1, T y1, T x2, T y2) {
     return sqrt(pow((x1 - x2), 2) + pow((y1 - y2), 2));
 }


 template <typename T>
 static inline float sigmoid(T const& x) {
     return (1. / (1. + exp(-x)));
 }


 template <typename T>
 static inline std::vector<float> sigmoid(const std::vector<T>& x) {
     std::vector<float> res;
     for (auto i : x) {
         res.push_back(1. / (1. + exp(-i)));
     }
     return res;
 }


 template <typename T>
 static inline std::vector<float> sigmoid(const T* x, int startptr, int calcnum) {
     std::vector<float> res;
     for (size_t i = startptr; i < (startptr + calcnum); i++)
     {
         res.push_back(1. / (1. + exp(-x[i])));
     }
     return res;
 }


 template <typename T, typename D>
 static inline std::vector<float> sigmoid(const T* x, D alpha, int startptr, int calcnum) {
     std::vector<float> res;
     for (size_t i = startptr; i < (startptr + calcnum); i++)
     {
         res.push_back(1. / (1. + exp(-x[i] * alpha)));
     }
     return res;
 }


template <typename T>
static inline std::vector<float> sigmoid(const T* x, int calcnum) {
    std::vector<float> res;
    for (size_t i = 0; i < calcnum; i++)
    {
        res.push_back(1. / (1. + exp(-x[i])));
    }
    return res;
}

template <typename T>
static void _sigmoid(T* x, int calcnum, bool inplace) {
    for (size_t i = 0; i < calcnum; i++)
    {
        x[i] = 1. / (1. + exp(-x[i]));
    }
}

template <typename T>
static void _sigmoid(T* x, int calcnum, float norm, bool inplace) {
    for (size_t i = 0; i < calcnum; i++)
    {
        x[i] = 1. / (1. + exp(-x[i] * norm));
    }
}

template <typename T>
static inline float arcSigmoid(T const& x) {
    return -log(1.f / x - 1);
}

template <typename T>
static inline float sumExp(const T* x, int startptr, int calcnum) {
    float res = 0.;
    for (size_t i = startptr; i < (startptr + calcnum); i++)
    {
        res += exp(x[i]);
    }
    return res;
}

template <typename T, typename D>
static inline float sumExp(const T* x, D alpha, int startptr, int calcnum) {
    float res = 0.;
    for (size_t i = startptr; i < (startptr + calcnum); i++)
    {
        res += exp(x[i] * alpha);
    }
    return res;
}


template <typename T>
static inline std::vector<float> softmax(const T* x, int startptr, int calcnum) {
    std::vector<float> res;
    auto total = sumExp(x, startptr, calcnum);
    for (size_t i = startptr; i < (startptr + calcnum); i++)
    {
        res.push_back(exp(x[i]) / total);
    }
    return res;
}

template <typename T, typename D>
static inline std::vector<float> softmax(const T* x, D alpha, int startptr, int calcnum) {
    std::vector<float> res;
    auto total = sumExp(x, alpha,startptr, calcnum);
    for (size_t i = startptr; i < (startptr + calcnum); i++)
    {
        res.push_back(exp(x[i])* alpha / total);
    }
    return res;
}

static inline std::vector<float> softmax_void_nan(std::vector<float> input)
{   
    float total = 0.f;
    for (auto x : input)
    {
        total += exp(x);
    }
    std::vector<float> result;
    for (auto x : input)
    {
        result.push_back(exp(x) / total);
    }
    return result;
}

template <typename T, typename D>
static inline std::vector<float> dfl(const T* x, D alpha, int startptr,int info_length) { // revised
    
    int one_bbox_info_length = info_length / 4;
    std::vector<float> res = { 0.f,0.f,0.f,0.f };
    for (int nums = 0; nums < 4; nums++) {
        std::vector<float> dfl_one;
        for (int i = 0; i < one_bbox_info_length; i++) {
            dfl_one.push_back(x[startptr + nums * one_bbox_info_length + i] * alpha);
        }
        std::vector<float> dfl_one_softmax = softmax_void_nan(dfl_one);
        for (int j = 0; j < one_bbox_info_length; j++) {
            res[nums] += (float)j * dfl_one_softmax[j];
        }
    }
    return res;
}

template <typename T>
static inline std::vector<float> dfl(const T* x, int info_length) {
    int one_bbox_info_length = info_length / 4;
    std::vector<float> res = { 0.f,0.f,0.f,0.f };
    for (int nums = 0; nums < 4; nums++) {
        std::vector<float> dfl_one;
        for (int i = 0; i < one_bbox_info_length; i++) {
            dfl_one.push_back(x[nums * one_bbox_info_length + i]);
        }
        std::vector<float> dfl_one_softmax = softmax_void_nan(dfl_one);
        for (int j = 0; j < one_bbox_info_length; j++) {
            res[nums] += (float)j * dfl_one_softmax[j];
        }
    }
    return res;
}

//@brief 将参数约束到一个范围内
//@param    x  输入参数
//@param    a  最小值
//@param    b  最大值
template <typename T>
static inline float checkBorder(T const& x, T const& a, T const& b) {
    if (x < a) {
        return a;
    }
    else if (x > b) {
        return b;
    }
    else {
        return x;
    }

}

//------------------------------------------------------------//
//topk sort 

template <typename T>
static inline void sorts(std::vector<std::pair<int,T>>& v) {
    std::stable_sort(v.begin(), v.end(),
        [](const std::pair<int, T>& pair1, const std::pair<int, T>& pair2) {
            return pair1.second > pair2.second;
        }
    );
}

template <typename T>
static inline std::vector<std::pair<int,T>> _topK(std::vector<std::pair<int,T>>& v, int k) {
    std::vector<std::pair<int,T>> tmp(v.begin(), v.begin() + k);
    sorts(tmp); 
    for (int i = k + 1; i < v.size(); ++i) {
        for (int j = 0; j < k; ++j) {
            if (v[i].second > tmp[j].second) {
                tmp.push_back(v[i]);
                sorts(tmp);
                tmp.pop_back();
                break;
            }
        }
    }
    return tmp;
}

template <typename T>
static inline std::vector<std::pair<int, T>> topK(std::vector<T>& v, int k) {
    std::vector<std::pair<int, T>> res;
    int index = 0;
    for (auto&& i : v) {
        res.push_back({ index,i });
        index++;
    }
    auto r = _topK(res, k);
    return r;
}