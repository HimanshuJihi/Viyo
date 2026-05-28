const fs = require('fs');
const vm = require('vm');
const html = fs.readFileSync('write-blog.html', 'utf8');
const scriptRegex = /<script.*?>([\s\S]*?)<\/script>/gi;
let match;
let count = 0;
while ((match = scriptRegex.exec(html)) !== null) {
  count++;
  let code = match[1];
  // Replace import/export with harmless statements so node syntax check works
  code = code.replace(/import\s+[\s\S]*?from\s+['\"].*?['\"];?/g, '');
  code = code.replace(/export\s+/g, '');
  try {
    new vm.Script(code);
    console.log(`Script ${count} passed syntax check`);
  } catch(e) {
    console.error(`Syntax error found in script ${count}:`, e.message);
  }
}
