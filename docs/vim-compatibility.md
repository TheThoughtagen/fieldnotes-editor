# Vim compatibility

FIELDNOTES uses Vim bindings by default. Presentation-mode changes preserve the same editor and Vim adapter; toggling Vim itself resets adapter-local mode state.

Matrix v1: 54 command families / 146 executable tokens (43 supported, 3 adapted, 8 unsupported families).

| Command | Classification | Exact behavior |
| --- | --- | --- |
| <code>normal, insert, replace</code> | supported | Upstream Vim modes preserve one document and adapter across presentation changes. |
| <code>h j k l</code> | supported | Move one character or display line. |
| <code>w W b B e E</code> | supported | Move by small or big words. |
| <code>0 ^ $</code> | supported | Move to line boundaries or first nonblank. |
| <code>gg G</code> | supported | Move to document boundaries or a counted line. |
| <code>f F t T ; ,</code> | supported | Find a character on the current line and repeat. |
| <code>%</code> | supported | Move between matching delimiters. |
| <code>{ } ( )</code> | supported | Move by paragraph or sentence. |
| <code>H M L</code> | supported | Move within the visible viewport. |
| <code>Ctrl-f Ctrl-b Ctrl-d Ctrl-u</code> | supported | Scroll by page or half-page. |
| <code>d{motion}</code> | supported | Delete the motion range. |
| <code>c{motion}</code> | supported | Change the motion range and enter insert mode. |
| <code>y{motion}</code> | supported | Yank the motion range. |
| <code>{count}{operator}{motion}</code> | supported | Apply deterministic numeric counts. |
| <code>dd cc yy</code> | supported | Apply the operator linewise. |
| <code>iw aw iW aW</code> | supported | Select inner or around word objects. |
| <code>is as</code> | supported | Select inner or around sentences. |
| <code>ip ap</code> | supported | Select inner or around Markdown paragraphs. |
| <code>i( a( i[ a[ i{ a{ i&lt; a&lt;</code> | supported | Select inside or around balanced pairs. |
| <code>i" a" i' a' i` a`</code> | supported | Select inside or around quote delimiters. |
| <code>it at</code> | adapted | Operate on HTMLBlock tag content or element; Markdown paragraphs outside HTML are unchanged. |
| <code>i a I A</code> | supported | Enter insert mode at the requested boundary. |
| <code>o O</code> | supported | Open a line below or above. |
| <code>r R s S</code> | supported | Replace characters or enter replacement/change mode. |
| <code>x X C D</code> | supported | Delete characters or the remainder of a line. |
| <code>J</code> | supported | Join lines. |
| <code>.</code> | supported | Repeat the last edit. |
| <code>u Ctrl-r</code> | supported | Undo or redo in the persistent CodeMirror history. |
| <code>~</code> | supported | Toggle character case. |
| <code>&lt;&lt; &gt;&gt; =</code> | supported | Indent, outdent, or format the selected lines. |
| <code>"a "_ "+ "*</code> | supported | Use named, black-hole, and platform registers where the host permits clipboard access. |
| <code>p P</code> | supported | After yl$, p on `abc` leaves `abca` at cursor 3; P leaves `abac` at cursor 3. |
| <code>m{letter} '{letter} `{letter}</code> | supported | Set and jump to document-local marks. |
| <code>q{register} @ {register} @@</code> | supported | Record and replay keyboard macros in the active document. |
| <code>/pattern ?pattern</code> | supported | Search forward or backward. |
| <code>n N</code> | supported | Repeat search in the same or opposite direction. |
| <code>* #</code> | supported | Search for the word under the cursor. |
| <code>:s/pattern/replacement/flags</code> | supported | Substitute in the addressed line. |
| <code>:%s/pattern/replacement/flags</code> | supported | Substitute throughout the document. |
| <code>:set ignorecase smartcase hlsearch</code> | supported | Configure the supported adapter-local search options. |
| <code>:noh</code> | supported | Clear search highlighting. |
| <code>:write :w</code> | adapted | After pending edit acknowledgement, request the owning NSDocument save action. |
| <code>:quit :q</code> | adapted | After pending edit acknowledgement, request window close and preserve the native unsaved-changes prompt. |
| <code>v; vld</code> | supported | Enter characterwise Visual mode; vld on `abcd` leaves `cd`, cursor 0, Normal mode. |
| <code>V; Vjd</code> | supported | Enter Visual Line mode; Vjd on `one\ntwo\nthree` leaves `three`, cursor 0, Normal mode. |
| <code>Ctrl-v; Ctrl-v jld</code> | supported | Enter Visual Block mode; Ctrl-v jld on `abc\ndef` leaves `c\nf`, cursor 0, Normal mode. |
| <code>:! {command}</code> | unsupported | Document unchanged; no native action; a visible unsupported-command diagnostic is shown. |
| <code>:source :function :let</code> | unsupported | Document unchanged; no native action; a visible unsupported-command diagnostic is shown. |
| <code>:map :nmap :imap :vmap</code> | unsupported | Document unchanged; no mapping is installed; a visible unsupported-command diagnostic is shown. |
| <code>:edit :read :file</code> | unsupported | Document unchanged; no path is opened; a visible unsupported-command diagnostic is shown. |
| <code>:buffer :bnext :bdelete</code> | unsupported | Document unchanged; no native action; a visible unsupported-command diagnostic is shown. |
| <code>:split :vsplit :tabnew :close</code> | unsupported | Document unchanged; no window action; a visible unsupported-command diagnostic is shown. |
| <code>:q! :w! :wq :x</code> | unsupported | Document unchanged; force semantics are never approximated; no native action is sent. |
| <code>:write {path}</code> | unsupported | Document unchanged; arbitrary paths are never accepted; no native action is sent. |

Unsupported commands never gain filesystem, shell, buffer, or window authority. `:write` and `:quit` are the only Ex commands adapted to native actions, and they run only after pending edits are acknowledged.
