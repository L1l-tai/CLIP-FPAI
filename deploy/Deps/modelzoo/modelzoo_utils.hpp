#pragma once

#include <random>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <vector>
#include <fstream>
#include <random>

#ifdef __linux__
#include <linux/fb.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mman.h>
#include <unistd.h>
#endif
#include "icraft-xir/core/network.h"
#include "icraft-xir/core/data.h"
#include <icraft-xrt/core/session.h>
#include <icraft-xrt/dev/host_device.h>
#include <icraft-xrt/dev/buyi_device.h> 
#include <icraft-xrt/dev/zg330_device.h>
#include <icraft-backends/hostbackend/utils.h>
#include <icraft-backends/hostbackend/backend.h>
#include <icraft-backends/buyibackend/buyibackend.h>
#include <icraft-backends/zg330backend/zg330backend.h>
#include <utils.hpp>
#include <PicPre.hpp>
#include <NetInfo.hpp>
#include <et_device.hpp>

using namespace icraft::xrt;
using namespace icraft::xir;
using namespace std::string_literals;
using namespace std::chrono;
using namespace std::chrono_literals;




std::vector<std::tuple<int, float, cv::Rect2f>> nms_soft(std::vector<int>& id_list, std::vector<float>& socre_list, std::vector<cv::Rect2f>& box_list, float IOU, int max_nms = 3000) {
	std::vector<std::tuple<int, float, cv::Rect2f>> filter_res;
	std::vector<std::tuple<int, float, cv::Rect2f>> nms_res;
	auto bbox_num = id_list.size();
	for (size_t i = 0; i < bbox_num; i++)
	{
		filter_res.push_back({ id_list[i],socre_list[i],box_list[i] });
	}

	std::stable_sort(filter_res.begin(), filter_res.end(),
		[](const std::tuple<int, float, cv::Rect2f>& tuple1, const std::tuple<int, float, cv::Rect2f>& tuple2) {
			return std::get<1>(tuple1) > std::get<1>(tuple2);
		}
	);

	int idx = 0;
	for (auto res : filter_res) {
		bool keep = true;
		for (int k = 0; k < nms_res.size() && keep; ++k) {
			if (std::get<0>(res) == std::get<0>(nms_res[k])) {
				if (1.f - jaccardDistance(std::get<2>(res), std::get<2>(nms_res[k])) > IOU) {
					keep = false;
				}
			}

		}
		if (keep == true)
			nms_res.emplace_back(res);
		if (idx > max_nms) {
			break;
		}
		idx++;
	}
	return nms_res;
};

std::vector<std::vector<float>> coordTrans(std::vector<std::tuple<int, float, cv::Rect2f>>& nms_res, PicPre& img, bool check_border = true) {
	std::vector<std::vector<float>> output_data;
	int left_pad = img.getPad().first;
	int top_pad = img.getPad().second;
	float ratio = img.getRatio().first;
	//std::cout <<"ratio: " << ratio << std::endl;
	for (auto&& res : nms_res) {
		float class_id = std::get<0>(res);
		float score = std::get<1>(res);
		auto box = std::get<2>(res);
		float x1 = (box.tl().x - left_pad) / ratio;
		float y1 = (box.tl().y - top_pad) / ratio;
		float x2 = (box.br().x - left_pad) / ratio;
		float y2 = (box.br().y - top_pad) / ratio;
		if (check_border) {
			x1 = checkBorder(x1, 0.f, (float)img.src_img.cols);
			y1 = checkBorder(y1, 0.f, (float)img.src_img.rows);
			x2 = checkBorder(x2, 0.f, (float)img.src_img.cols);
			y2 = checkBorder(y2, 0.f, (float)img.src_img.rows);
		}
		float w = x2 - x1;
		float h = y2 - y1;
		//bbox：左上角点和wh
		output_data.emplace_back(std::vector<float>({ class_id, x1, y1, w, h, score }));
	}
	return output_data;
}

void visualize(std::vector<std::vector<float>>& output_res, const cv::Mat& img, const std::string resRoot, const std::string name, const std::vector<std::string>& names) {
	std::default_random_engine e;
	std::uniform_int_distribution<unsigned> u(10, 200);

	for (auto res : output_res) {
		int class_id = (int)res[0];
		float x1 = res[1];
		float y1 = res[2];
		float w = res[3];
		float h = res[4];
		float score = res[5];
		cv::Scalar color_ = cv::Scalar(u(e), u(e), u(e));
		cv::rectangle(img, cv::Rect(x1, y1, w, h), color_, 2);
		std::stringstream ss;
		ss << std::fixed << std::setprecision(2) << score;
		std::string s = std::to_string(class_id) + "_" + names[class_id] + " " + ss.str();
		auto s_size = cv::getTextSize(s, cv::FONT_HERSHEY_DUPLEX, 0.5, 1, 0);
		cv::rectangle(img, cv::Point(x1 - 1, y1 - s_size.height - 7), cv::Point(x1 + s_size.width, y1 - 2), color_, -1);
		cv::putText(img, s, cv::Point(x1, y1 - 2), cv::FONT_HERSHEY_DUPLEX, 0.5, cv::Scalar(255, 255, 255), 0.2);
	}
#ifdef _WIN32
	cv::imshow("results", img);
	cv::waitKey(0);
#elif __linux__
	std::string save_path = resRoot + '/' + name;
	std::regex rgx("\\.(?!.*\\.)"); // 匹配最后一个点号（.）之前的位置，且该点号后面没有其他点号
	std::string RES_PATH = std::regex_replace(save_path, rgx, "_result.");
	cv::imwrite(RES_PATH, img);
#endif

}

void saveRes(std::vector<std::vector<float>>& output_res, std::string resRoot, std::string name) {
	std::string save_path = resRoot + '/' + name;
	std::regex reg(R"(\.(\w*)$)");
	save_path = std::regex_replace(save_path, reg, ".txt");
	std::ofstream outputFile(save_path);
	if (!outputFile.is_open()) {
		std::cout << "Create txt file fail." << std::endl;
	}

	for (auto i : output_res) {
		for (auto j : i) {
			outputFile << j << " ";
		}
		outputFile << "\n";
	}
	outputFile.close();
}

/**
 * @description:        在cvMat上绘制信息
 * @param input_img     输入的cvMat
 * @param text          右上角信息，一般为fps数值
 * @param model_name    左上角信息，一般为模型名称
 * @param color         信息颜色
 * @return {*}
 * @notes: 
 */
void drawText(cv::Mat& input_img, const std::string& text, const std::string& model_name, cv::Scalar color){

	int font_face = cv::FONT_HERSHEY_COMPLEX;
	double font_scale = 2;
	int thickness = 2;
    int baseline;
    auto text_size = cv::getTextSize(text, font_face, font_scale, thickness, &baseline);
    cv::Point origin; 
    origin.x = 0;
    origin.y = 0;
	// origin.x = input_img.cols / 2 - text_size.width / 2;
	// origin.y = input_img.rows / 2 + text_size.height / 2;
    //cv::rectangle(input_img, origin, cv::Point(origin.x + text_size.width + 10, origin.y + text_size.height + 10), (0, 0, 0), -1);
	cv::putText(input_img, text, cv::Point(origin.x, origin.y + + text_size.height), font_face, font_scale, color, thickness);

    cv::Point model_name_pos;
    
    auto model_name_text_size = cv::getTextSize(model_name, font_face, font_scale, thickness, &baseline);
    model_name_pos.x = input_img.cols - model_name_text_size.width;
    model_name_pos.y = 0;
    //cv::rectangle(input_img, model_name_pos, cv::Point(model_name_pos.x + model_name_text_size.width, model_name_pos.y + model_name_text_size.height + 10), (0, 0, 0), -1);
	cv::putText(input_img, model_name, cv::Point(model_name_pos.x, model_name_pos.y + + model_name_text_size.height), font_face, font_scale, color, thickness);
}

void drawText(cv::Mat& input_img, const std::string& text, cv::Scalar color) {

	int font_face = cv::FONT_HERSHEY_COMPLEX;
	double font_scale = 2;
	int thickness = 2;
	int baseline;
	auto text_size = cv::getTextSize(text, font_face, font_scale, thickness, &baseline);
	cv::Point origin;
	origin.x = 0;
	origin.y = 0;
	// origin.x = input_img.cols / 2 - text_size.width / 2;
	// origin.y = input_img.rows / 2 + text_size.height / 2;
	//cv::rectangle(input_img, origin, cv::Point(origin.x + text_size.width + 10, origin.y + text_size.height + 10), (0, 0, 0), -1);
	cv::putText(input_img, text, cv::Point(origin.x, origin.y + +text_size.height), font_face, font_scale, color, thickness);
}

void drawTextTopLeft(cv::Mat& input_img, const std::string& text, cv::Scalar color) {

	int font_face = cv::FONT_HERSHEY_COMPLEX;
	double font_scale = 1;
	int thickness = 1;
	int baseline;
	auto text_size = cv::getTextSize(text, font_face, font_scale, thickness, &baseline);
	cv::Point origin;
	origin.x = 10;
	origin.y = 10;
	// origin.x = input_img.cols / 2 - text_size.width / 2;
	// origin.y = input_img.rows / 2 + text_size.height / 2;
	//cv::rectangle(input_img, origin, cv::Point(origin.x + text_size.width + 10, origin.y + text_size.height + 10), (0, 0, 0), -1);
	cv::putText(input_img, text, cv::Point(origin.x, origin.y + +text_size.height), font_face, font_scale, color, thickness);
}

void drawTextFourConer(cv::Mat& input_img, const std::string& text, const std::string& fps, cv::Scalar color) {

	int font_face = cv::FONT_HERSHEY_COMPLEX;
	double font_scale = 1;
	int thickness = 1;
	int baseline;
	auto text_size = cv::getTextSize(text, font_face, font_scale, thickness, &baseline);
	cv::Point origin;
	origin.x = 10;
	origin.y = 10;

	cv::putText(input_img, fps, cv::Point(10, 10 + text_size.height), font_face, font_scale, color, thickness);

	cv::putText(input_img, text, cv::Point(input_img.cols - 10 - text_size.width, 10 + text_size.height), font_face, font_scale, color, thickness);

	cv::putText(input_img, text, cv::Point(10, input_img.rows - 10 - text_size.height), font_face, font_scale, color, thickness);

	cv::putText(input_img, text, cv::Point(input_img.cols - 10 - text_size.width, input_img.rows - 10 - text_size.height), font_face, font_scale, color, thickness);
}

void drawTextTwoConer(cv::Mat& input_img, const std::string& text, const std::string& fps, cv::Scalar color) {

	int font_face = cv::FONT_HERSHEY_COMPLEX;
	double font_scale = 1;
	int thickness = 1;
	int baseline;
	auto text_size = cv::getTextSize(text, font_face, font_scale, thickness, &baseline);
	cv::Point origin;
	origin.x = 10;
	origin.y = 10;
	cv::putText(input_img, fps, cv::Point(10, 10 + text_size.height), font_face, font_scale, color, thickness);
	cv::putText(input_img, text, cv::Point(input_img.cols - 10 - text_size.width, 10 + text_size.height), font_face, font_scale, color, thickness);
}



const int kColorMap[][3] = { {255, 128, 0}, {255, 153, 51}, {255, 178, 102}, {230, 230, 0}, {255, 153, 255},
							 {153, 204, 255}, {255, 102, 255}, {255, 51, 255}, {102, 178, 255},  {51, 153, 255},
							 {255, 153, 153}, {255, 102, 102},  {255, 51, 51}, {153, 255, 153}, {102, 255, 102},
							 {51, 255, 51}, {0, 255, 0}, {0, 0, 255}, {255, 0, 0},  {128, 255, 255} };
std::default_random_engine e;
std::uniform_int_distribution<unsigned> u(0, 255);
cv::Scalar randomColor() {
	return cv::Scalar(u(e), u(e), u(e));
}

cv::Scalar classColor(int id) {
    return cv::Scalar(kColorMap[id%20][0], kColorMap[id%20][1], kColorMap[id%20][2]);
}


void FlipPer4(int16_t* tensor_data, int size) {
	for (int i = 0; i < size; i += 4) {
		int16_t a0 = tensor_data[i + 0];
		int16_t a1 = tensor_data[i + 1];
		int16_t a2 = tensor_data[i + 2];
		int16_t a3 = tensor_data[i + 3];

		tensor_data[i + 3] = a0;
		tensor_data[i + 2] = a1;
		tensor_data[i + 1] = a2;
		tensor_data[i + 0] = a3;
	}
}






/**
 * @description: 正确版本的nms
 * @param box_list      推理出来的的bbox列表
 * @param socre_list    置信度列表
 * @param conf          筛选置信度阈值
 * @param iou           筛选的iou阈值
 * @return {*}
 * @notes:
 */
std::vector<int> nms(std::vector<cv::Rect>& box_list, std::vector<float>& socre_list, std::vector<int>& id_list, const float& conf, const float& iou, const int& NOC) {

	std::vector<int> nms_indices;
	for (int class_id = 0; class_id < NOC; class_id++) {
		std::vector<std::pair<float, int> > score_index_vec;

		for (size_t i = 0; i < socre_list.size(); ++i) {
			if (socre_list[i] > conf && id_list[i] == class_id) {
				score_index_vec.emplace_back(std::make_pair(socre_list[i], i));
			}
		}

		std::stable_sort(score_index_vec.begin(), score_index_vec.end(),
			[](const std::pair<float, int>& pair1, const std::pair<float, int>& pair2) {return pair1.first > pair2.first; });

		for (size_t i = 0; i < score_index_vec.size(); ++i) {
			const int idx = score_index_vec[i].second;
			bool keep = true;
			for (int k = 0; k < nms_indices.size() && keep; ++k) {
				if (1.f - jaccardDistance(box_list[idx], box_list[nms_indices[k]]) > iou) {
					keep = false;
				}
			}
			if (keep == true)
				nms_indices.emplace_back(idx);
		}
	}
	return nms_indices;
}