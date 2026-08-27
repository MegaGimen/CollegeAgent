const fs = require('fs');
const TurndownService = require('turndown');

const turndownService = new TurndownService({
  headingStyle: 'atx',
  codeBlockStyle: 'fenced'
});

turndownService.addRule('iframe', {
  filter: 'iframe',
  replacement: function (content, node) {
    const src = node.getAttribute('src');
    const title = node.getAttribute('title') || 'Embedded Media';
    if (src) {
      return `\n[📺 ${title}](${src})\n`;
    }
    return '';
  }
});

const html = fs.readFileSync('/home/collegeagent/opioid-overdose-intervention-body.html', 'utf8');
const markdown = turndownService.turndown(html);

console.log(markdown);
