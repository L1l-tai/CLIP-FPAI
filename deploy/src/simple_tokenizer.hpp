#pragma once
// CLIP BPE tokenizer – 纯 C++ 实现, 对齐 gen_input_ids.py 的 SimpleTokenizer
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <set>
#include <regex>
#include <sstream>
#include <fstream>
#include <cstdint>
#include <algorithm>
#include <climits>

static const int SOT = 49406;
static const int EOT = 49407;
static const int MAX_LEN = 77;

// chr(codepoint) -> UTF-8 string
static std::string unicode_char(int cp) {
    std::string r;
    if (cp < 0x80) { r += (char)cp; }
    else if (cp < 0x800) {
        r += (char)(0xC0 | (cp >> 6));
        r += (char)(0x80 | (cp & 0x3F));
    }
    return r;
}

class SimpleTokenizer {
public:
    SimpleTokenizer(const std::string& merges_path) {
        // ---- 1. bytes_to_unicode() – 与 Python 完全等效 ----
        std::set<int> printable;
        for (int b = 33;  b <= 126; b++) printable.insert(b);  // '!'..'~'
        for (int b = 161; b <= 172; b++) printable.insert(b);  // '¡'..'¬'
        for (int b = 174; b <= 255; b++) printable.insert(b);  // '®'..'ÿ'

        int n = 0;
        for (int b = 0; b < 256; b++) {
            if (printable.count(b))
                byte_encoder_[b] = std::string(1, (char)b);
            else
                byte_encoder_[b] = unicode_char(256 + n++);
        }

        // ---- 2. 构建 vocab (按 ID 顺序) ----
        // IDs 0-255: byte_encoder values
        for (int b = 0; b < 256; b++)
            vocab_by_id_.push_back(byte_encoder_[b]);
        // IDs 256-511: byte_encoder + "</w>"
        for (int b = 0; b < 256; b++)
            vocab_by_id_.push_back(byte_encoder_[b] + "</w>");

        // ---- 3. 加载 merges.txt ----
        std::ifstream ifs(merges_path);
        if (!ifs) {
            fprintf(stderr, "[TOK] ERROR: cannot open %s\n", merges_path.c_str());
            ok_ = false; return;
        }
        std::string line;
        std::getline(ifs, line); // skip header
        int rank = 0;
        while (std::getline(ifs, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty()) continue;
            size_t sp = line.find(' ');
            if (sp == std::string::npos) continue;
            std::string a = line.substr(0, sp);
            std::string b = line.substr(sp + 1);
            bpe_ranks_[line] = rank++;          // key: "a b", value: rank
            vocab_by_id_.push_back(a + b);       // ID = 512 + rank-1
        }
        // Special tokens: IDs 49406, 49407
        vocab_by_id_.push_back("<start_of_text>");
        vocab_by_id_.push_back("<end_of_text>");

        // ---- 4. encoder: token string -> ID ----
        for (size_t i = 0; i < vocab_by_id_.size(); i++)
            encoder_[vocab_by_id_[i]] = (int)i;

        // ---- 5. 正则 (与 gen_input_ids.py 相同) ----
        pat_ = std::regex(
            R"(<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[A-Za-z]+|[0-9]+|[^\sA-Za-z0-9]+)");

        ok_ = true;
    }

    bool ok() const { return ok_; }

    // tokenize(text) -> 77 int32 token IDs (对齐 Python tokenize)
    std::vector<int32_t> tokenize(const std::string& text) {
        std::vector<int32_t> result(MAX_LEN, 0);
        auto ids = encode(text);
        std::vector<int32_t> tokens = { SOT };
        tokens.insert(tokens.end(), ids.begin(), ids.end());
        tokens.push_back(EOT);
        if ((int)tokens.size() > MAX_LEN) {
            tokens.resize(MAX_LEN);
            tokens.back() = EOT;
        }
        for (size_t i = 0; i < tokens.size(); i++)
            result[i] = tokens[i];
        return result;
    }

private:
    std::string byte_encoder_[256];
    std::vector<std::string> vocab_by_id_;
    std::unordered_map<std::string, int> encoder_;    // token string -> ID
    std::unordered_map<std::string, int> bpe_ranks_;  // "a b" -> rank
    std::unordered_map<std::string, std::string> cache_;
    std::regex pat_;
    bool ok_ = false;

    std::vector<int> encode(const std::string& text) {
        std::vector<int> bpe_tokens;
        std::string low = text;
        std::transform(low.begin(), low.end(), low.begin(), ::tolower);
        // strip
        size_t s = low.find_first_not_of(" \t");
        size_t e = low.find_last_not_of(" \t\r");
        if (s == std::string::npos) return bpe_tokens;
        low = low.substr(s, e - s + 1);

        std::sregex_iterator it(low.begin(), low.end(), pat_);
        std::sregex_iterator end;
        for (; it != end; ++it) {
            std::string token = it->str();
            // byte-encode: each byte -> unicode char
            std::string be;
            for (unsigned char c : token)
                be += byte_encoder_[(int)c];
            std::string merged = bpe(be);
            // split by space, lookup each sub-token
            std::istringstream iss(merged);
            std::string sub;
            while (iss >> sub) {
                auto ei = encoder_.find(sub);
                if (ei != encoder_.end())
                    bpe_tokens.push_back(ei->second);
            }
        }
        return bpe_tokens;
    }

    std::string bpe(const std::string& token) {
        auto ci = cache_.find(token);
        if (ci != cache_.end()) return ci->second;

        // build word: last char + "</w>"
        std::vector<std::string> word;
        for (size_t i = 0; i < token.size(); i++) {
            if (i + 1 == token.size())
                word.push_back(std::string(1, token[i]) + "</w>");
            else
                word.push_back(std::string(1, token[i]));
        }

        auto get_pairs = [](const std::vector<std::string>& w) {
            std::unordered_set<std::string> ps;
            for (size_t i = 0; i + 1 < w.size(); i++)
                ps.insert(w[i] + " " + w[i + 1]);
            return ps;
        };

        auto pairs = get_pairs(word);
        if (pairs.empty()) {
            cache_[token] = token + "</w>";
            return cache_[token];
        }

        while (true) {
            std::string best;
            int best_r = INT_MAX;
            for (const auto& p : pairs) {
                auto ri = bpe_ranks_.find(p);
                if (ri != bpe_ranks_.end() && ri->second < best_r) {
                    best_r = ri->second;
                    best = p;
                }
            }
            if (best.empty()) break;

            size_t sp = best.find(' ');
            std::string a = best.substr(0, sp);
            std::string b = best.substr(sp + 1);

            std::vector<std::string> nw;
            size_t i = 0;
            while (i < word.size()) {
                size_t j = word.size();
                for (size_t k = i; k < word.size(); k++)
                    if (word[k] == a) { j = k; break; }
                for (size_t k = i; k < j; k++)
                    nw.push_back(word[k]);
                i = j;
                if (i < word.size() && word[i] == a && i + 1 < word.size() && word[i + 1] == b) {
                    nw.push_back(a + b);
                    i += 2;
                } else if (i < word.size()) {
                    nw.push_back(word[i]);
                    i += 1;
                }
            }
            word = nw;
            if (word.size() == 1) break;
            pairs = get_pairs(word);
        }

        std::string result;
        for (size_t i = 0; i < word.size(); i++) {
            if (i) result += " ";
            result += word[i];
        }
        cache_[token] = result;
        return result;
    }
};
