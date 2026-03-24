#include "opencv2/opencv.hpp"
#include <string>



class  PicPre {
public:
	//src_dims: c,h,w
	std::tuple<int, int, int> src_dims;
	cv::Mat ori_img;
	cv::Mat src_img;
	cv::Mat dst_img;

	enum ImreadModes {
		IMREAD_UNCHANGED = -1, //!< If set, return the loaded image as is (with alpha channel, otherwise it gets cropped). Ignore EXIF orientation.
		IMREAD_GRAYSCALE = 0,  //!< If set, always convert image to the single channel grayscale image (codec internal conversion).
		IMREAD_COLOR = 1,  //!< If set, always convert image to the 3 channel BGR color image.
		IMREAD_ANYDEPTH = 2,  //!< If set, return 16-bit/32-bit image when the input has the corresponding depth, otherwise convert it to 8-bit.
		IMREAD_ANYCOLOR = 4,  //!< If set, the image is read in any possible color format.
		IMREAD_LOAD_GDAL = 8,  //!< If set, use the gdal driver for loading the image.
		IMREAD_REDUCED_GRAYSCALE_2 = 16, //!< If set, always convert image to the single channel grayscale image and the image size reduced 1/2.
		IMREAD_REDUCED_COLOR_2 = 17, //!< If set, always convert image to the 3 channel BGR color image and the image size reduced 1/2.
		IMREAD_REDUCED_GRAYSCALE_4 = 32, //!< If set, always convert image to the single channel grayscale image and the image size reduced 1/4.
		IMREAD_REDUCED_COLOR_4 = 33, //!< If set, always convert image to the 3 channel BGR color image and the image size reduced 1/4.
		IMREAD_REDUCED_GRAYSCALE_8 = 64, //!< If set, always convert image to the single channel grayscale image and the image size reduced 1/8.
		IMREAD_REDUCED_COLOR_8 = 65, //!< If set, always convert image to the 3 channel BGR color image and the image size reduced 1/8.
		IMREAD_IGNORE_ORIENTATION = 128 //!< If set, do not rotate the image according to EXIF's orientation flag.
	};

	enum InterpolationFlags {
		/** nearest neighbor interpolation */
		INTER_NEAREST = 0,
		/** bilinear interpolation */
		INTER_LINEAR = 1,
		/** bicubic interpolation */
		INTER_CUBIC = 2,
		/** resampling using pixel area relation. It may be a preferred method for image decimation, as
		it gives moire'-free results. But when the image is zoomed, it is similar to the INTER_NEAREST
		method. */
		INTER_AREA = 3,
		/** Lanczos interpolation over 8x8 neighborhood */
		INTER_LANCZOS4 = 4,
		/** Bit exact bilinear interpolation */
		INTER_LINEAR_EXACT = 5,
		/** Bit exact nearest neighbor interpolation. This will produce same results as
		the nearest neighbor method in PIL, scikit-image or Matlab. */
		INTER_NEAREST_EXACT = 6,
		/** mask for interpolation codes */
		INTER_MAX = 7,
		/** flag, fills all of the destination image pixels. If some of them correspond to outliers in the
		source image, they are set to zero */
		WARP_FILL_OUTLIERS = 8,
		/** flag, inverse transformation

		For example, #linearPolar or #logPolar transforms:
		- flag is __not__ set: \f$dst( \rho , \phi ) = src(x,y)\f$
		- flag is set: \f$dst(x,y) = src( \rho , \phi )\f$
		*/
		WARP_INVERSE_MAP = 16
	};

	enum ResizeModes {
		BOTH_SIDE = 0,          //按照dst的大小直接resize，可能发生变形
		LONG_SIDE = 1,          //按照dst的长边计算resize ratio
		SHORT_SIDE = 2          //按照dst的短边计算resize ratio
	};

	enum PadModes {
		BR = 0,                 //只在右下pad
		AROUND = 1              //四周都做pad
	};

	PicPre() = default;
	//构造函数，读入图片，获取src_img dims
	PicPre(const std::string& filename, int flags = IMREAD_COLOR) {
		this->src_img = cv::imread(filename, flags);
		this->ori_img = cv::imread(filename, flags);
		this->src_dims = { src_img.channels(), src_img.rows, src_img.cols };
		if (this->src_img.channels() == 3){
			cv::cvtColor(this->src_img, this->src_img, cv::COLOR_BGR2RGB);
		}
		
	}

	//构造函数，读入cv mat，获取src_img dims
	PicPre(const cv::Mat& img) {
		this->src_img = img.clone();
		this->ori_img = img.clone();
		this->src_dims = { src_img.channels(), src_img.rows, src_img.cols };
		if (this->src_img.channels() == 3){
			cv::cvtColor(this->src_img, this->src_img, cv::COLOR_BGR2RGB);
		}

	}

	//resize，dst_shape_hw:<resized h,resized w>
	virtual PicPre& Resize(std::pair<int, int> dst_shape_hw, int mode = LONG_SIDE, int interpolation = INTER_LINEAR) {
		int ori_img_h = std::get<1>(this->src_dims);
		int ori_img_w = std::get<2>(this->src_dims);
		int resized_h = dst_shape_hw.first;
		int resized_w = dst_shape_hw.second;

		float ratio_h = (float)resized_h / (float)ori_img_h;
		float ratio_w = (float)resized_w / (float)ori_img_w;

		this->_dst_shape = { resized_h, resized_w };

		switch (mode) {
		case 0: {
			cv::resize(this->src_img, this->dst_img, cv::Size(resized_w, resized_h), 0, 0, interpolation);
			this->_real_resized_ratio = { ratio_h,ratio_w };
			this->_real_resized_hw = { resized_h,resized_w };
			break;
		}

		case 1: {
			float ratio = (std::min)(ratio_w, ratio_h);
			int real_resized_h = int(std::round(ori_img_h * ratio));
			int real_resized_w = int(std::round(ori_img_w * ratio));
			cv::resize(this->src_img, this->dst_img, cv::Size(real_resized_w, real_resized_h), 0, 0, interpolation);
			this->_real_resized_ratio = { ratio,ratio };
			this->_real_resized_hw = { real_resized_h,real_resized_w };
			break;
		}

		case 2: {
			float ratio = (std::max)(ratio_w, ratio_h);
			int real_resized_h = int(std::round(ori_img_h * ratio));
			int real_resized_w = int(std::round(ori_img_w * ratio));
			cv::resize(this->src_img, this->dst_img, cv::Size(real_resized_w, real_resized_h), 0, 0, interpolation);
			this->_real_resized_ratio = { ratio,ratio };
			this->_real_resized_hw = { real_resized_h,real_resized_w };
			break;
		}

		default: {
			throw "wrong resize mode!";
			exit(EXIT_FAILURE);
		}

		}

		return *this;
	}

	/*
	* @brief 默认resize之后做pad，主要为了补成dst_img的形状，同时获取pad_info，<left, top>，为后处理坐标转换用；如果想直接pad，可以对对象的src_img,直接进行copymakeboder操作
	* @param pad_mode：pad的方式
	* @return none
	*/
	virtual void rPad(int pad_mode = BR) {
		switch (pad_mode) {
		case 0: {
			int dh = std::abs(this->_dst_shape.first - this->_real_resized_hw.first);
			int dw = std::abs(this->_dst_shape.second - this->_real_resized_hw.second);
			cv::copyMakeBorder(this->dst_img, this->dst_img, 0, dh, 0, dw, cv::BORDER_CONSTANT, cv::Scalar(114, 114, 114));
			this->_pad_info = { 0,0 };
			break;
		}

		case 1: {
			float dh = std::abs(this->_dst_shape.first - this->_real_resized_hw.first) / 2.f;
			float dw = std::abs(this->_dst_shape.second - this->_real_resized_hw.second) / 2.f;
			int top = int(std::round(dh - 0.1));
			int bottom = int(std::round(dh + 0.1));
			int left = int(std::round(dw - 0.1));
			int right = int(std::round(dw + 0.1));
			cv::copyMakeBorder(this->dst_img, this->dst_img, top, bottom, left, right, cv::BORDER_CONSTANT, cv::Scalar(114, 114, 114));
			this->_pad_info = { left,top };
			break;
		}

		default:
			throw "wrong pad mode!";
			exit(EXIT_FAILURE);
		}

	}

	//默认resize之后做crop
	virtual void rCenterCrop(std::pair<int, int> crop_shape_hw) {
		int resized_h = this->_real_resized_hw.first;
		int resized_w = this->_real_resized_hw.second;
		int crop_h = crop_shape_hw.first;
		int crop_w = crop_shape_hw.second;

		bool xxx = (resized_h >= crop_h) && (resized_w >= crop_w);
		if (!xxx) {
			std::cerr << "wrong: picpre crop shape bigger than inputs " << std::endl;
		}

		int start_h = (resized_h - crop_h) / 2;
		int start_w = (resized_w - crop_w) / 2;
		//std::cout << start_h << std::endl;
		//std::cout << start_w << std::endl;
		this->dst_img = this->dst_img(cv::Rect(start_w, start_h, crop_w, crop_h)).clone();
	}

	// return _real_resized_ratio: <ratio_h,ratio_w>
	virtual std::pair<float, float> getRatio() { return _real_resized_ratio; }

	// return _pad_info: <left,top>
	virtual std::pair<int, int> getPad() { return _pad_info; }



protected:

	//dst_shape：target img shape <h,w>;也用来存放中间结果的大小;
	std::pair<int, int> _dst_shape;

	// _real_resized_ratio: <ratio_h,ratio_w>
	std::pair<float, float> _real_resized_ratio;

	//_real_resized_hw: <resized_h, resized_w>
	std::pair<int, int> _real_resized_hw;

	// _pad_info: <left,top>
	std::pair<int, int> _pad_info;

};

