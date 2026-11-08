// This adds a release to the Sparkle appcast in updates.xml.rss. It also creates the file for the
// first release. The newest items go first.
//
//   node update-appcast.js <appcast> <version> <build> <url> <length> <signature> <minimum macOS> [notes.md]
const fs = require('fs');

const [file, version, build, url, length, signature, minimumSystem, notesFile] =
  process.argv.slice(2);
if (!minimumSystem) {
  console.error(
    'usage: node update-appcast.js <appcast> <version> <build> <url> <length> <signature> <minimum macOS> [notes]',
  );
  process.exit(1);
}

const repository = 'https://github.com/nich227/ClipDeck';

const skeleton = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClipDeck</title>
    <link>${repository}</link>
    <description>ClipDeck updates</description>
    <language>en</language>
    <!-- items -->
  </channel>
</rss>
`;

// Release notes support paragraphs, bullets, headings, bold text, code, and links.
function htmlFromMarkdown(markdown) {
  const inline = (text) =>
    text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');

  const blocks = markdown.trim().split(/\n{2,}/);

  return blocks
    .map((block) => {
      const lines = block.split('\n').map((line) => line.trim());

      if (lines.every((line) => /^[-*] /.test(line))) {
        const items = lines
          .map((line) => `      <li>${inline(line.slice(2))}</li>`)
          .join('\n');
        return `      <ul>\n${items}\n      </ul>`;
      }

      const heading = lines[0].match(/^(#{1,6})\s+(.*)$/);
      if (heading) {
        // The update window is small, so do not use headings above H3.
        const level = Math.max(3, Math.min(6, heading[1].length));
        return `      <h${level}>${inline(heading[2])}</h${level}>`;
      }

      return `      <p>${inline(lines.join(' '))}</p>`;
    })
    .join('\n');
}

// The item contains the notes. Adding sparkle:releaseNotesLink would make the update window show
// the whole GitHub release page instead of only what changed.
function releaseNotes() {
  if (!notesFile || !fs.existsSync(notesFile)) {
    return `      <p>ClipDeck ${version}.</p>`;
  }
  return htmlFromMarkdown(fs.readFileSync(notesFile, 'utf8'));
}

const notes = `${releaseNotes()}
      <p>
        <a href="${repository}/releases/tag/v${version}">All the details for ${version}</a>
      </p>`;

const item = `    <item>
      <title>${version}</title>
      <pubDate>${new Date().toUTCString()}</pubDate>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${minimumSystem}</sparkle:minimumSystemVersion>
      <description>
        <![CDATA[
${notes}
        ]]>
      </description>
      <enclosure url="${url}" length="${length}" type="application/octet-stream" sparkle:edSignature="${signature}"/>
    </item>
`;

const marker = '    <!-- items -->\n';
let appcast = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : skeleton;
if (!appcast.includes(marker)) {
  console.error('appcast has no <!-- items --> marker');
  process.exit(1);
}
if (appcast.includes(`<sparkle:version>${build}</sparkle:version>`)) {
  console.error(`build ${build} is already in the appcast`);
  process.exit(1);
}

fs.writeFileSync(file, appcast.replace(marker, marker + item));
console.log(`added ${version} (build ${build}) to ${file}`);
