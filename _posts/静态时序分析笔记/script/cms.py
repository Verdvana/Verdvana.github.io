import pandas as pd

# 加载Excel文件
file_path = 'cms.xlsx'
sheet_name = 'clock'

# 读取Excel文件
df = pd.read_excel(file_path, sheet_name=sheet_name, engine='openpyxl')

# 将DataFrame转换为矩阵（列表的列表）
matrix = df.values.tolist()

# 打印矩阵
for row in matrix:
    print(row)