"""Publish compiler errors as concise GitHub Actions annotations."""
import pathlib
import re
import sys


def escape(value):
    return value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def main():
    path = pathlib.Path(sys.argv[1])
    if not path.exists():
        print('::error::Build log was not generated.')
        return
    seen = set()
    for line in path.read_text(errors='replace').splitlines():
        if 'error:' not in line or line in seen:
            continue
        seen.add(line)
        match = re.match(r'^(.*?):(\d+):(\d+): error: (.*)$', line)
        if match:
            filename, row, column, message = match.groups()
            try:
                filename = str(pathlib.Path(filename).relative_to(pathlib.Path.cwd()))
            except ValueError:
                pass
            filename = escape(filename).replace(',', '%2C').replace(':', '%3A')
            print(f'::error file={filename},line={row},col={column}::{escape(message)}')
        else:
            print('::error::' + escape(line))
        if len(seen) >= 30:
            break


if __name__ == '__main__':
    main()
