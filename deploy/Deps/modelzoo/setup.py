from setuptools import setup, find_packages

setup(
    name="pyrtutils",
    version="3.30",
    packages=find_packages(),
    author="chendong",
    author_email="chendong@fmsh.com.cn",
    description="Some dependency functions to facilitate the development of pyrt",
    license= "Apache License",
    url="https://gitee.com/mxh-spiger/modelzoo_utils/tree/mzu_3.7.0/",

    # 添加以下行以指定所需的Python版本
    python_requires='>=3.8',
)