const fs = require('fs');
let code = fs.readFileSync('write-blog.html', 'utf8');

const startIndex = code.indexOf(`        window.addFSText = function() {`);
const endIndex = code.indexOf(`        // Audio Library`);

if (startIndex === -1 || endIndex === -1) {
    console.log("Could not find boundaries");
    process.exit(1);
}

const before = code.substring(0, startIndex);
const after = code.substring(endIndex);

const newTextEditorLogic = `        // --- Advanced Text Editor Logic ---
        let fsActiveTextState = { color: '#ffffff', font: 'font-classic', align: 'center', bgState: 0 }; // 0=None, 1=Translucent, 2=Inverted
        let fsActiveTextElement = null;
        let fsMentionTimer = null;

        window.addFSText = function(event) {
            if(event) event.stopPropagation();
            fsActiveTextElement = null; // Reset for new text
            document.getElementById('fs-text-input-area').value = '';
            document.getElementById('fs-text-input-modal').style.display = 'flex';
            document.getElementById('fs-text-input-area').focus();
            applyFSTextStylesToTextarea();
        };

        window.fsCloseTextEditor = function() {
            const text = document.getElementById('fs-text-input-area').value.trim();
            if (text) {
                if (fsActiveTextElement) {
                    // Update existing element
                    fsActiveTextElement.innerText = text;
                    fsActiveTextElement.className = \`fs-draggable fs-text \${fsActiveTextState.font}\`;
                    fsActiveTextElement.style.textAlign = fsActiveTextState.align;
                    
                    fsActiveTextElement.classList.remove('bg-active', 'bg-inverted');
                    if(fsActiveTextState.bgState === 1) fsActiveTextElement.classList.add('bg-active');
                    else if(fsActiveTextState.bgState === 2) {
                        fsActiveTextElement.classList.add('bg-inverted');
                        fsActiveTextElement.style.backgroundColor = fsActiveTextState.color;
                        fsActiveTextElement.style.color = (fsActiveTextState.color === '#ffffff' || fsActiveTextState.color === 'rgb(255, 255, 255)') ? '#000000' : '#ffffff';
                    } else {
                        fsActiveTextElement.style.color = fsActiveTextState.color;
                        fsActiveTextElement.style.backgroundColor = 'transparent';
                    }
                } else {
                    // Create new element
                    renderFSTextOnCanvas(text);
                }
            } else if (fsActiveTextElement) {
                fsActiveTextElement.remove(); // Delete if text is cleared
            }
            document.getElementById('fs-text-input-modal').style.display = 'none';
            document.getElementById('fs-mention-dropdown').style.display = 'none';
            fsActiveTextElement = null;
        };

        function renderFSTextOnCanvas(text) {
            const div = document.createElement('div');
            div.className = \`fs-draggable fs-text \${fsActiveTextState.font}\`;
            div.innerText = text;
            div.style.textAlign = fsActiveTextState.align;
            
            if(fsActiveTextState.bgState === 1) div.classList.add('bg-active');
            if(fsActiveTextState.bgState === 2) {
                div.classList.add('bg-inverted');
                div.style.backgroundColor = fsActiveTextState.color;
                div.style.color = (fsActiveTextState.color === '#ffffff' || fsActiveTextState.color === 'rgb(255, 255, 255)') ? '#000000' : '#ffffff';
            } else {
                div.style.color = fsActiveTextState.color;
            }
            
            let isD = false; let sX, sY;
            div.addEventListener('touchstart', e => { isD = true; const t = e.touches[0]; const r = div.getBoundingClientRect(); sX = t.clientX - r.left - r.width/2; sY = t.clientY - r.top - r.height/2; }, {passive:true});
            div.addEventListener('touchmove', e => { if(!isD) return; const t = e.touches[0]; div.style.left = (t.clientX - sX) + 'px'; div.style.top = (t.clientY - sY) + 'px'; }, {passive:true});
            div.addEventListener('touchend', () => isD = false);
            div.addEventListener('mousedown', e => { isD = true; const r = div.getBoundingClientRect(); sX = e.clientX - r.left - r.width/2; sY = e.clientY - r.top - r.height/2; });
            div.addEventListener('mousemove', e => { if(!isD) return; div.style.left = (e.clientX - sX) + 'px'; div.style.top = (e.clientY - sY) + 'px'; });
            div.addEventListener('mouseup', () => isD = false);
            div.addEventListener('click', () => editFSText(div));

            document.getElementById('fs-overlays-container').appendChild(div);
        }

        window.editFSText = (div) => {
            fsActiveTextElement = div;
            document.getElementById('fs-text-input-area').value = div.innerText;
            
            fsActiveTextState.color = div.style.color || '#ffffff';
            if (div.classList.contains('bg-active')) fsActiveTextState.bgState = 1;
            else if (div.classList.contains('bg-inverted')) fsActiveTextState.bgState = 2;
            else fsActiveTextState.bgState = 0;
            fsActiveTextState.font = Array.from(div.classList).find(c => c.startsWith('font-')) || 'font-classic';
            fsActiveTextState.align = div.style.textAlign || 'center';
            
            document.getElementById('fs-text-input-modal').style.display = 'flex';
            document.getElementById('fs-text-input-area').focus();
            applyFSTextStylesToTextarea();
        };

        window.handleFSTextareaInput = (el) => {
            el.style.height = 'auto';
            el.style.height = (el.scrollHeight) + 'px';
        };

        window.fsSetTextColor = (hex) => {
            fsActiveTextState.color = hex;
            document.getElementById('fs-text-color-btn').style.color = hex;
            applyFSTextStylesToTextarea();
        };
        
        window.fsSetFont = (fontClass, btn) => {
            document.querySelectorAll('#fs-text-input-modal .font-circle').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            fsActiveTextState.font = fontClass;
            applyFSTextStylesToTextarea();
        };

        window.fsToggleTextAlign = () => {
            const alignMap = { 'center': 'left', 'left': 'right', 'right': 'center' };
            const iconMap = { 'center': 'align-center', 'left': 'align-left', 'right': 'align-right' };
            fsActiveTextState.align = alignMap[fsActiveTextState.align];
            document.getElementById('fs-text-align-btn').innerHTML = \`<i data-lucide="\${iconMap[fsActiveTextState.align]}"></i>\`;
            lucide.createIcons();
            applyFSTextStylesToTextarea();
        };

        window.fsToggleTextBg = () => {
            fsActiveTextState.bgState = (fsActiveTextState.bgState + 1) % 3;
            applyFSTextStylesToTextarea();
        };

        window.fsToggleColorPicker = () => {
            const picker = document.getElementById('fs-color-selector');
            if (picker.style.display === 'none') {
                const colors = ['#ffffff', '#000000', '#ef4444', '#f59e0b', '#10b981', '#3b82f6', '#a855f7', '#ec4899'];
                picker.innerHTML = colors.map(c => \`<div class="color-circle" style="background: \${c};" onclick="window.fsSetTextColor('\${c}')"></div>\`).join('');
                picker.style.display = 'flex';
            } else {
                picker.style.display = 'none';
            }
        };

        function applyFSTextStylesToTextarea() {
            const ta = document.getElementById('fs-text-input-area');
            ta.className = fsActiveTextState.font;
            ta.style.textAlign = fsActiveTextState.align;
            
            if(fsActiveTextState.bgState === 0) {
                ta.style.background = 'transparent';
                ta.style.color = fsActiveTextState.color;
            } else if (fsActiveTextState.bgState === 1) {
                ta.style.background = 'rgba(0,0,0,0.7)';
                ta.style.color = fsActiveTextState.color;
            } else {
                ta.style.background = fsActiveTextState.color;
                ta.style.color = (fsActiveTextState.color === '#ffffff' || fsActiveTextState.color === 'rgb(255, 255, 255)') ? '#000000' : '#ffffff';
            }
        }

        window.addFSSticker = function(emoji) {
            const div = document.createElement('div');
            div.className = 'fs-draggable fs-sticker';
            div.innerText = emoji;
            div.style.cssText = 'position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); font-size: 80px; cursor: move; pointer-events: auto;';
            
            let isD = false; let sX, sY;
            div.addEventListener('touchstart', e => { isD = true; const t = e.touches[0]; const r = div.getBoundingClientRect(); sX = t.clientX - r.left - r.width/2; sY = t.clientY - r.top - r.height/2; }, {passive:true});
            div.addEventListener('touchmove', e => { if(!isD) return; const t = e.touches[0]; div.style.left = (t.clientX - sX) + 'px'; div.style.top = (t.clientY - sY) + 'px'; }, {passive:true});
            div.addEventListener('touchend', () => isD = false);
            
            div.addEventListener('mousedown', e => { isD = true; const r = div.getBoundingClientRect(); sX = e.clientX - r.left - r.width/2; sY = e.clientY - r.top - r.height/2; });
            div.addEventListener('mousemove', e => { if(!isD) return; div.style.left = (e.clientX - sX) + 'px'; div.style.top = (e.clientY - sY) + 'px'; });
            div.addEventListener('mouseup', () => isD = false);
            
            document.getElementById('fs-overlays-container').appendChild(div);
        };
\r\n`;

code = before + newTextEditorLogic + after;
fs.writeFileSync('write-blog.html', code, 'utf8');
console.log("Fix applied");
