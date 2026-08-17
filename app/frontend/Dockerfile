FROM python:3.12-slim

WORKDIR /app

COPY frontend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY shared ./shared
COPY frontend/main.py ./main.py

CMD ["python", "main.py"]
