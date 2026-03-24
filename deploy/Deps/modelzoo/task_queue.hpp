#include <array>
#include <condition_variable>
#include <list>
#include <locale>
#include <memory>
#include <mutex>
#include <atomic>
#include <stdint.h>

#include "fmt/core.h"

#define QUEUE_STOPED 1
#define QUEUE_EMPTY 2
#define QUEUE_FULL 3


static const int APP_ERR_QUEUE_STOPED = 1;
static const int APP_ERR_QUEUE_EMPTY = 2;
static const int APP_ERROR_QUEUE_FULL = 3;
static const int DEFAULT_MAX_QUEUE_SIZE = 64;

struct InputMessageForIcore
{
    int buffer_index;   //
    std::vector<icraft::xrt::Tensor> image_tensor;
    bool ai;
    bool error_frame = false;
};


struct IcoreMessageForPost
{
    int buffer_index;   //
    std::vector<icraft::xrt::Tensor> icore_tensor;
    bool ai;
    bool error_frame = false;
};


template <typename T>
inline bool all_empty(std::array<T, 3> vec) {
    return (vec[0].empty() && vec[1].empty() && vec[2].empty());
}

template <typename T>
inline int total_size(std::array<T, 3> vec) {
    return (vec[0].size() + vec[1].size() + vec[2].size());
}


template <typename T>
inline void clear_all(std::array<T, 3> vec) {
    vec[0].clear();
    vec[1].clear();
    vec[2].clear();
}



template <typename T> class Queue {
public:
    Queue(uint32_t maxSize = DEFAULT_MAX_QUEUE_SIZE) : maxSize_(maxSize), isStoped_(false) 
    {

    }

    Queue(int source_num, int buffer_num, uint32_t maxSize = DEFAULT_MAX_QUEUE_SIZE) 
            : maxSize_(maxSize), isStoped_(false),
              src_num_(source_num), buffer_num_(buffer_num) {

        src_cond_vec_ = std::vector<std::condition_variable>(source_num);
        src_inqueu_cnt_ = std::vector<int>(source_num, 0);
        src_mutex_ = std::vector<std::mutex>(source_num);
    }

    ~Queue() {}

    int Pop(T &item)
    {
        std::unique_lock<std::mutex> lock(mutex_);

        while (all_empty(queue_priority_) && !isStoped_) {
            emptyCond_.wait(lock);
        }

        if (isStoped_) {
            return APP_ERR_QUEUE_STOPED;
        }

        int ret = 0;
        if (all_empty(queue_priority_)) {
            return APP_ERR_QUEUE_EMPTY;
        } else {
            for (int i = priority_total_- 1; i >= 0; --i) {
                if (queue_priority_[i].empty()) {
                    continue;
                } 
                ret = i;
                item = queue_priority_[i].front();
                queue_priority_[i].pop_front();
                break;
            }
        }

        fullCond_.notify_one();
        return ret;
    }

    int Push(const T& item, bool isWait = true)
    {
        std::unique_lock<std::mutex> lock(mutex_);

        while (queue_priority_[0].size() >= maxSize_ && isWait && !isStoped_) {
            fullCond_.wait(lock);
        }

        if (isStoped_) {
            return 1;
        }

        if (queue_priority_[0].size() >= maxSize_) {
            return APP_ERROR_QUEUE_FULL;
        }
        queue_priority_[0].push_back(item);

        emptyCond_.notify_one();

        return 0;
    }


    int Push(const T& item, int src_index)
    {
        if (src_index > src_num_ -1) {
            throw std::runtime_error(fmt::format("[Task_Queue - Push()]src index larger than src number"));
            return -1;
        }
        
        std::unique_lock<std::mutex> src_lock(src_mutex_[src_index]);

        while (src_inqueu_cnt_[src_index] >= buffer_num_   && !isStoped_) {
            src_cond_vec_[src_index].wait(src_lock);
        }

        std::unique_lock<std::mutex> lock(mutex_);
        while (total_size(queue_priority_) >= maxSize_  && !isStoped_) {
            fullCond_.wait(lock);
        }

        if (isStoped_) {
            return 1;
        }

        if (total_size(queue_priority_) >= maxSize_) {
            return APP_ERROR_QUEUE_FULL;
        }
        queue_priority_[0].push_back(item);     // default priority
        ++src_inqueu_cnt_[src_index];
        emptyCond_.notify_one();

        return 0;
    }


    int Push(const T& item, int src_index, int priority)
    {
        
        if (src_index > src_num_ -1) {
            throw std::runtime_error(fmt::format("[Task_Queue - Push()], src index larger than src number"));
            return -1;
        }

        if (priority > priority_total_ -1) {
            throw std::runtime_error(fmt::format("[Task_Queue - Push()], priority larger than biggest priority level"));
            return -1;
        }
            
        
        std::unique_lock<std::mutex> src_lock(src_mutex_[src_index]);

        while (src_inqueu_cnt_[src_index] >= buffer_num_   && !isStoped_) {
            src_cond_vec_[src_index].wait(src_lock);
        }

        std::unique_lock<std::mutex> lock(mutex_);
        while (total_size(queue_priority_) >= maxSize_  && !isStoped_) {
            fullCond_.wait(lock);
        }

        if (isStoped_) {
            return 1;
        }

        if (total_size(queue_priority_) >= maxSize_) {
            return APP_ERROR_QUEUE_FULL;
        }
        queue_priority_[priority].push_back(item);
        ++src_inqueu_cnt_[src_index];
        emptyCond_.notify_one();

        return 0;
    }


    // int Push_Front(const T &item, int src_index, int priority)
    // {
    //     std::unique_lock<std::mutex> lock(mutex_);

    //     while (queue_.size() >= maxSize_ && isWait && !isStoped_) {
    //         fullCond_.wait(lock);
    //     }

    //     if (isStoped_) {
    //         return APP_ERR_QUEUE_STOPED;
    //     }

    //     if (queue_.size() >= maxSize_) {
    //         return APP_ERROR_QUEUE_FULL;
    //     }

    //     queue_.push_front(item);

    //     emptyCond_.notify_one();

    //     return 0;
    // }

    void Stop()
    {
        {
            std::unique_lock<std::mutex> lock(mutex_);
            isStoped_ = true;
        }

        fullCond_.notify_all();
        emptyCond_.notify_all();
    }

    void Restart()
    {
        {
            std::unique_lock<std::mutex> lock(mutex_);
            isStoped_ = false;
        }
    }

    void PopMark(int src_index) 
    {
        
        if (src_index > src_num_ -1) {
            throw std::runtime_error(fmt::format("[Task_Queue - PopMark()], src index larger than src number"));
            return ;
        }
        src_cond_vec_[src_index].notify_one();
        --src_inqueu_cnt_[src_index];

    }

    int GetBackItem(T &item)
    {
        if (isStoped_) {
            return APP_ERR_QUEUE_STOPED;
        }

        if (all_empty(queue_priority_).empty()) {
            return APP_ERR_QUEUE_EMPTY;
        }

        for (int i = priority_total_- 1; i >= 0; --i) {
        if (queue_priority_[i].empty())
            continue;
        item = queue_priority_[i].back();

        }
        return 0;
    }

    std::mutex *GetLock()
    {
        return &mutex_;
    }

    int IsFull()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return total_size(queue_priority_) >= maxSize_;
    }

    int GetSize(int priority)
    {
        
        return priority < priority_total_ ? queue_priority_[priority].size() : -1;
    }

    int IsEmpty()
    {
        return all_empty(queue_priority_).empty();
    }

    void Clear()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        clear_all(queue_priority_);
    }

private:
    std::array<std::list<T>, 3> queue_priority_;
    std::mutex mutex_;
    std::condition_variable emptyCond_;
    std::condition_variable fullCond_;
    uint32_t maxSize_;

    // for n src
    std::vector<std::mutex> src_mutex_;
    std::vector<std::condition_variable> src_cond_vec_;
    std::vector<int> src_inqueu_cnt_;
    unsigned int src_num_ = 1;
    unsigned int buffer_num_ = 4;

    int priority_total_ = 3;

    bool isStoped_;
};
