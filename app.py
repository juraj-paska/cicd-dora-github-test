"""Minimal Flask website for cicd-dora-github-test.

Serves a single page on / and a health check on /health.
Run in production via gunicorn (see Dockerfile); `python app.py`
starts the Flask dev server for local use.
"""
from flask import Flask

app = Flask(__name__)

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Hello cicd-dora-github-test</title>
  <style>
    body {
      font-family: system-ui, sans-serif;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100vh;
      margin: 0;
      background: #0f172a;
      color: #f8fafc;
    }
    h1 {
      font-size: 4rem;
    }
  </style>
</head>
<body>
  <h1>Hello from cicd-dora-github-test</h1>
</body>
</html>
"""


@app.route("/")
def index():
    return PAGE


@app.route("/health")
def health():
    return {"status": "ok"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
