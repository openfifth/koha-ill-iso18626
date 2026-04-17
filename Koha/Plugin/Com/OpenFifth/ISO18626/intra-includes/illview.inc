[% BLOCK backend_jsinclude %]
<style>
    #iso18626-messages {
        margin-top: 1.5rem;
    }
    #iso18626-messages h4 {
        margin-bottom: 0.75rem;
    }
    #iso18626-messages-table th,
    #iso18626-messages-table td {
        padding: 0.4rem 0.6rem;
        vertical-align: top;
    }
    .iso18626-toggle {
        background: none;
        border: none;
        color: #0070a8;
        cursor: pointer;
        padding: 0;
        font-size: 0.9em;
        text-decoration: underline;
    }
    .iso18626-payload {
        display: none;
        margin-top: 0.4rem;
        white-space: pre-wrap;
        font-family: monospace;
        font-size: 0.85em;
        background: #f5f5f5;
        padding: 0.5rem;
        border-radius: 3px;
        max-height: 20rem;
        overflow-y: auto;
    }
</style>
<script>
document.addEventListener('DOMContentLoaded', function () {
    var illrequest_id = new URLSearchParams(window.location.search).get('illrequest_id');
    if (!illrequest_id) return;

    var panel = document.querySelector('.page-section');
    if (!panel) return;

    var container = document.createElement('div');
    container.id = 'iso18626-messages';
    container.style.display = 'none';
    panel.appendChild(container);

    function escHtml(str) {
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    fetch('/api/v1/contrib/iso18626/ill_requests/' + illrequest_id + '/messages', {
        headers: { 'Accept': 'application/json' }
    })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (messages) {
        if (!messages || messages.length === 0) return;

        var rows = messages.map(function (msg, i) {
            var dt = new Date(msg.timestamp.replace(' ', 'T'));
            var formatted = isNaN(dt.getTime())
                ? escHtml(msg.timestamp)
                : dt.toLocaleDateString() + ' ' + dt.toLocaleTimeString();
            var toggleId = 'iso18626-payload-' + i;
            var prettyContent;
            try {
                prettyContent = JSON.stringify(JSON.parse(msg.content), null, 2);
            } catch (e) {
                prettyContent = msg.content;
            }
            return '<tr>'
                + '<td>' + formatted + '</td>'
                + '<td>' + escHtml(msg.type) + '</td>'
                + '<td>'
                +   '<button class="iso18626-toggle" data-target="' + toggleId + '">Show payload</button>'
                +   '<pre id="' + toggleId + '" class="iso18626-payload">' + escHtml(prettyContent) + '</pre>'
                + '</td>'
                + '</tr>';
        }).join('');

        container.innerHTML =
            '<h4>ISO18626 messages</h4>'
            + '<table id="iso18626-messages-table" class="table table-bordered table-striped">'
            + '<thead><tr><th>Timestamp</th><th>Type</th><th>Payload</th></tr></thead>'
            + '<tbody>' + rows + '</tbody>'
            + '</table>';
        container.style.display = 'block';

        container.addEventListener('click', function (e) {
            var btn = e.target.closest('.iso18626-toggle');
            if (!btn) return;
            var pre = document.getElementById(btn.dataset.target);
            if (!pre) return;
            var visible = pre.style.display === 'block';
            pre.style.display = visible ? 'none' : 'block';
            btn.textContent = visible ? 'Show payload' : 'Hide payload';
        });
    });
});
</script>
[% END %]
