[% BLOCK backend_jsinclude %]
<style>
    #iso18626-messages { margin-top: 1.5rem; }
    #iso18626-messages h4 { margin-bottom: 0.75rem; }
    #iso18626-messages-table { width: auto; }
    #iso18626-messages-table th,
    #iso18626-messages-table td { padding: 0.4rem 0.6rem; vertical-align: top; }
    #iso18626-msg-modal .nested-table { padding-left: 20px; border-left: 1px solid #ccc; }
    #iso18626-msg-modal fieldset.rows legend { cursor: pointer; font-weight: bold; }
</style>

<div class="modal fade" id="iso18626-msg-modal" tabindex="-1" aria-hidden="true">
    <div class="modal-dialog modal-lg">
        <div class="modal-content">
            <div class="modal-header alert-warning confirmation">
                <h1 id="iso18626-msg-modal-title"></h1>
                <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
            </div>
            <div class="modal-body" id="iso18626-msg-modal-body"></div>
            <div class="modal-footer">
                <button type="button" class="btn btn-default" data-bs-dismiss="modal">Close</button>
            </div>
        </div>
    </div>
</div>

<script>
document.addEventListener('DOMContentLoaded', function () {
    var illrequest_id = new URLSearchParams(window.location.search).get('illrequest_id');
    var panel = document.querySelector('.page-section');
    if (!illrequest_id || !panel) return;

    // ── utilities ────────────────────────────────────────────────────────────

    var escHtml    = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    var capitalize = s => s.charAt(0).toUpperCase() + s.slice(1);

    // Recursively renders a JSON value as an HTML string.
    // Objects become tables, arrays become comma-separated values, primitives are escaped.
    // The nested-table indent style is only applied from depth 1 onwards (i.e. not on the
    // first-level table directly inside each accordion section).
    function renderValue(val, depth) {
        depth = depth || 0;
        if (val == null) return '';
        if (Array.isArray(val)) return val.map(function (v) { return renderValue(v, depth); }).join(', ');
        if (typeof val === 'object')
            return '<table' + (depth > 0 ? ' class="nested-table"' : '') + '>'
                + Object.entries(val).map(([k, v]) => '<tr><th>' + escHtml(k) + '</th><td>' + renderValue(v, depth + 1) + '</td></tr>').join('')
                + '</table>';
        return escHtml(String(val));
    }

    // Renders the top-level keys of a message object as collapsible accordion sections.
    // Keys are sorted by the ISO18626 field order; 'header' starts collapsed.
    var KEY_ORDER = ['action', 'header', 'confirmationHeader', 'bibliographicInfo', 'messageInfo', 'statusInfo', 'retryInfo', 'deliveryInfo'];
    function renderAccordion(obj) {
        var i = 0;
        return Object.keys(obj)
            .sort((a, b) => {
                var ia = KEY_ORDER.indexOf(a), ib = KEY_ORDER.indexOf(b);
                return (ia < 0 ? Infinity : ia) - (ib < 0 ? Infinity : ib);
            })
            .map(function (key) {
                var val = obj[key];
                if (val !== null && typeof val === 'object') {
                    var id = 'iso18626-c' + (i++), collapsed = key === 'header';
                    return '<fieldset class="rows">'
                        + '<legend data-bs-toggle="collapse" data-bs-target="#' + id + '" aria-expanded="' + !collapsed + '"' + (collapsed ? ' class="collapsed"' : '') + '>'
                        + '<i class="fa fa-caret-down"></i> ' + escHtml(capitalize(key))
                        + '</legend>'
                        + '<ol id="' + id + '" class="collapse' + (collapsed ? '' : ' show') + '">' + renderValue(val) + '</ol>'
                        + '</fieldset>';
                }
                return '<div class="fs-2 fw-bold p-2">' + escHtml(capitalize(key) + ': ' + (val ?? '')) + '</div>';
            }).join('');
    }

    // The plugin stores some messages without the outer type-key wrapper (e.g. just
    // {header:{...}, messageInfo:{...}} instead of {supplyingAgencyMessage:{...}}).
    // This normalises both formats to { typeKey, inner }.
    var MESSAGE_TYPES = ['request', 'requestConfirmation', 'requestingAgencyMessage',
        'requestingAgencyMessageConfirmation', 'supplyingAgencyMessage', 'supplyingAgencyMessageConfirmation'];
    function parseContent(contentStr, msgType) {
        var parsed   = JSON.parse(contentStr);
        var firstKey = Object.keys(parsed)[0];
        return MESSAGE_TYPES.includes(firstKey)
            ? { typeKey: firstKey, inner: parsed[firstKey] }
            : { typeKey: msgType,  inner: parsed };
    }

    // Extracts a one-line human-readable summary from a stored message.
    function getMessageSummary(contentStr, msgType) {
        try {
            var inner = parseContent(contentStr, msgType).inner;
            if (inner?.action != null)                            return 'Action: ' + inner.action;
            if (inner?.messageInfo?.reasonForMessage != null)     return 'Reason: ' + inner.messageInfo.reasonForMessage;
            if (inner?.confirmationHeader?.messageStatus != null) return 'Status: ' + inner.confirmationHeader.messageStatus;
        } catch (e) {}
        return '';
    }

    // ── modal ────────────────────────────────────────────────────────────────

    function openModal(contentStr, msgType) {
        try {
            var parsed = parseContent(contentStr, msgType);
            document.getElementById('iso18626-msg-modal-title').textContent = 'ISO18626 message: ' + parsed.typeKey;
            document.getElementById('iso18626-msg-modal-body').innerHTML = '<div class="accordion">' + renderAccordion(parsed.inner) + '</div>';
            bootstrap.Modal.getOrCreateInstance(document.getElementById('iso18626-msg-modal')).show();
        } catch (e) { console.error('ISO18626: could not parse message', e); }
    }

    // ── fetch & render ───────────────────────────────────────────────────────

    var container = document.createElement('div');
    container.id = 'iso18626-messages';
    container.style.display = 'none';
    panel.appendChild(container);

    fetch('/api/v1/contrib/iso18626/ill_requests/' + illrequest_id + '/messages', { headers: { Accept: 'application/json' } })
        .then(r => r.ok ? r.json() : null)
        .then(function (messages) {
            if (!messages?.length) return;

            var rows = messages.map(function (msg, i) {
                var dt     = new Date(msg.timestamp.replace(' ', 'T'));
                var ts     = isNaN(dt) ? escHtml(msg.timestamp) : dt.toLocaleDateString() + ' ' + dt.toLocaleTimeString();
                var isConf = msg.type.toLowerCase().includes('confirmation');
                var icon   = msg.type.toLowerCase().includes('request') ? 'fa-upload' : 'fa-download';
                return '<tr data-conf="' + (isConf ? 1 : 0) + '"' + (isConf ? ' style="display:none"' : '') + '>'
                    + '<td><i class="fas ' + icon + '" aria-hidden="true"></i>&nbsp;' + escHtml(msg.type) + '</td>'
                    + '<td>' + escHtml(getMessageSummary(msg.content, msg.type)) + '</td>'
                    + '<td>' + ts + '</td>'
                    + '<td><button class="btn btn-default" data-idx="' + i + '"><i class="fas fa-envelope"></i>&nbsp;View message</button></td>'
                    + '</tr>';
            }).join('');

            container.innerHTML =
                '<h4>ISO18626 messages</h4>'
                + '<label style="display:block;margin-bottom:.5rem"><input type="checkbox" id="iso18626-show-conf" style="margin-right:.4rem">Show confirmations</label>'
                + '<table id="iso18626-messages-table" class="table table-bordered table-striped">'
                + '<thead><tr><th>Type</th><th>Information</th><th>Timestamp</th><th>Content</th></tr></thead>'
                + '<tbody>' + rows + '</tbody>'
                + '</table>';
            container.style.display = 'block';

            container.querySelector('tbody').addEventListener('click', function (e) {
                var btn = e.target.closest('button[data-idx]');
                if (btn) { var msg = messages[+btn.dataset.idx]; openModal(msg.content, msg.type); }
            });

            document.getElementById('iso18626-show-conf').addEventListener('change', function () {
                container.querySelectorAll('tr[data-conf="1"]').forEach(row => row.style.display = this.checked ? '' : 'none');
            });
        });
});
</script>
[% END %]
