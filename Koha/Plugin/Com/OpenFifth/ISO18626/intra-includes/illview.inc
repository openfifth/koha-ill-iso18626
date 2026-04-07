[% BLOCK backend_jsinclude %]
<style>
    #reprints_desk_status {
        padding-top: 20px;
        display: none;
    }
    .reprints_desk_transaction {
        display: flex;
    }
    .reprints_desk_transaction > * {
        width: 25%;
    }
    #transactions_header {
        font-weight: 700;
        margin-bottom: 0.5rem;
    }
    #reprints_desk_header {
        margin-bottom: 1rem;
    }
</style>
<script>
    document.addEventListener('DOMContentLoaded', function(){

        // Hide "Mark request READY" button if an Order ID exists
        if( $('li.orderid').length !== 0 ){
            $('#ill-toolbar-btn-ready').hide();
        }

        var field_map = [% whole.field_map_json %];

        var reprintsDeskIdContainer = $(".requestmeta-ReprintsDesk_identifier");
        if (!reprintsDeskIdContainer) return;

        // We clone so we can extract the ReprintsDeskID without affecting the displayed markup
        var containerClone = reprintsDeskIdContainer.clone();

        $('.ill-view-panel .panel-body').first().append('<div id="reprints_desk_status" class="rows"></div>');

        containerClone.find('span.label').remove();
        var reprintsDeskId = containerClone.text().replace(/ |\n/g,'');

        if (!reprintsDeskId || reprintsDeskId.length === 0) return;

        $.post({
            url: '/api/v1/contrib/reprintsdesk/Order_GetOrderInfo',
            data: JSON.stringify({ requestId: reprintsDeskId }),
            contentType: 'application/json'
        })
            .done(function(resp, status) {
                var body = resp.result;
                if (
                    !body ||
                    !body.IsSuccessful ||
                    !body.HistoryTransactions ||
                    !body.HistoryTransactions.TranHistory ||
                    body.HistoryTransactions.TranHistory.length === 0
                ) return;

                var transactionsHeader = '<div id="transactions_header" class="reprints_desk_transaction">' +
                    '<div class="date">' + _('Date') + '</div>' +
                    '<div class="branch">' + _('Branch name') + '</div>' +
                    '<div class="code">' + _('ReprintsDesk code') + '</div>' +
                    '<div class="state">' + _('ReprintsDesk state') + '</div>' +
                    '</div>';

                var transactions = [];
                body.HistoryTransactions.TranHistory.forEach(function(tran) {
                    var tranDate = new Date(tran.TransactionDate);
                    var tranMarkup = '<div class="reprints_desk_transaction">' +
                        '<div class="date">' + tranDate.toLocaleDateString() + ' ' + tranDate.toLocaleTimeString() + '</div>' +
                        '<div class="branch">' + tran.BranchName + '</div>' +
                        '<div class="code">' + tran.ReprintsDeskCode + '</div>' +
                        '<div class="state">' + tran.StateType + '</div>' +
                        '</div>';
                    transactions.push(tranMarkup);
                });

                $('#reprints_desk_status').append(
                    '<h1 id="reprints_desk_header">' + _('ReprintsDesk history') + '</h1>' +
                    transactionsHeader + 
                    transactions.join('')
                ).show();
            });

    });
</script>
[% END %]