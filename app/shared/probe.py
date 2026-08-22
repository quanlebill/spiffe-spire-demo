import json
import sys
import urllib.error
import urllib.request


def main():
    url = sys.argv[1]
    body = sys.argv[2] if len(sys.argv) > 2 else None
    request = urllib.request.Request(url, method="POST" if body else "GET")
    if body:
        request.add_header("Content-Type", "application/json")
        request.data = body.encode()
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            print(f"HTTP {response.status}")
            print(response.read().decode(errors="replace"))
    except urllib.error.HTTPError as error:
        print(f"HTTP {error.code}")
        print(error.read().decode(errors="replace"))
    except Exception as error:
        print(f"CONNECTION FAILED: {type(error).__name__}: {error}")
        sys.exit(1)


if __name__ == "__main__":
    main()
