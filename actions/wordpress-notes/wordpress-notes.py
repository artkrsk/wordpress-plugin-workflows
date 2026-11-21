#!/usr/bin/env python3
"""Saves a WordPress release's Field Guide and developer notes from make.wordpress.org/core as text files.

Usage: wordpress-notes.py <major.minor> <directory>

Writes <directory>/INDEX.md (every saved file with its title and link), field-guide.md and one file per
developer note, named after the post. Prints count=<documents saved> on stdout: 0 while the release has
no Field Guide and no developer notes yet.
"""

import html.parser
import json
import pathlib
import re
import sys
import urllib.parse
import urllib.request

API = 'https://make.wordpress.org/core/wp-json/wp/v2'


def get(path, **params):
    request = urllib.request.Request(
        f'{API}/{path}?{urllib.parse.urlencode(params)}',
        headers={'User-Agent': 'wordpress-notes'},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


class Text(html.parser.HTMLParser):
    """A post's HTML as plain text: headings, list items and code blocks keep their shape."""

    BLOCKS = {'p', 'div', 'ul', 'ol', 'table', 'tr', 'blockquote', 'figure', 'br', 'hr'}

    def __init__(self):
        super().__init__()
        self.parts = []
        # Depth inside a glossary tooltip: its definition would repeat on every use of the term
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if self.hidden:
            self.hidden += tag == 'span'
        elif tag == 'span' and 'glossary-item-hidden-content' in (dict(attrs).get('class') or ''):
            self.hidden = 1
        elif re.fullmatch(r'h[1-6]', tag):
            self.parts.append('\n\n' + '#' * int(tag[1]) + ' ')
        elif tag == 'li':
            self.parts.append('\n- ')
        elif tag == 'pre':
            self.parts.append('\n```\n')
        elif tag in self.BLOCKS:
            self.parts.append('\n\n')

    def handle_endtag(self, tag):
        if self.hidden:
            self.hidden -= tag == 'span'
        elif tag == 'pre':
            self.parts.append('\n```\n')
        elif tag in self.BLOCKS or re.fullmatch(r'h[1-6]', tag):
            self.parts.append('\n\n')

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def text(markup):
    parser = Text()
    parser.feed(markup)
    return re.sub(r'\n{3,}', '\n\n', ''.join(parser.parts)).strip()


def main():
    version, directory = sys.argv[1], pathlib.Path(sys.argv[2])
    slug = version.replace('.', '-')
    tags = {tag['slug']: tag['id'] for tag in get('tags', slug=f'field-guide,{slug},dev-notes-{slug}', _fields='id,slug')}
    fields = 'slug,link,title.rendered,content.rendered'

    posts = []
    if 'field-guide' in tags and slug in tags:
        guides = get('posts', **{'tags[terms]': f"{tags['field-guide']},{tags[slug]}", 'tags[operator]': 'AND', '_fields': fields})
        posts += [('field-guide', guide) for guide in guides[:1]]
    if f'dev-notes-{slug}' in tags:
        notes = get('posts', tags=tags[f'dev-notes-{slug}'], per_page=100, order='asc', _fields=fields)
        posts += [(note['slug'], note) for note in notes]

    if posts:
        directory.mkdir(parents=True, exist_ok=True)
        index = [f'# WordPress {version}: Field Guide and developer notes', '']
        for name, post in posts:
            title = text(post['title']['rendered'])
            (directory / f'{name}.md').write_text(f"# {title}\n\nSource: {post['link']}\n\n{text(post['content']['rendered'])}\n")
            index.append(f"- {name}.md: {title} ({post['link']})")
        (directory / 'INDEX.md').write_text('\n'.join(index) + '\n')
    print(f'count={len(posts)}')


main()
