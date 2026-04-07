[% USE Koha %]
[% USE Asset %]
[% USE raw %]

[% SET koha_version = Koha.Version %]

[% cwd = whole.cwd %]

[% IF whole.error %]
  [% IF whole.status == 'missing_fields' %]
    <p><em>Please Note:</em> Some mandatory fields are missing.</p>
  [% ELSIF whole.status == 'missing_branch' %]
    <p><em>Please Note:</em> Branch is a mandatory field.</p>
  [% ELSIF whole.status == 'invalid_borrower' %]
    <p><em>Please Note:</em> The borrower details you entered are invalid.</p>
  [% ELSIF whole.status == 'invalid_branch' %]
    <p><em>Please Note:</em> The branch you chose is invalid.</p>
  [% ELSIF whole.status == 'api' %]
    <p><em>Please Note:</em> there was an error whilst communicating with the remote service.</p>
  [% ELSIF whole.status == 'missing_query' %]
    <p><em>Please Note:</em> You did not enter a search query.</p>
  [% ELSIF whole.message %]
    <p><em>[% whole.message %]</em></p>
  [% ELSE %]
    <p><em>Unhandled error</em></p>
  [% END %]
[% END %]

[% IF whole.stage == "commit" %]
<p>We have now created your request.</p>

[% ELSIF whole.stage == "init" %]
<div role="alert" class="alert alert-warning" id="request-lookup" style="display: none">
  Checking item availability via Reprints Desk
  <img src="[% interface | html %]/[% theme | html %]/img/spinner-small.gif" alt="" />
</div>
<div role="alert" class="alert alert-success" id="request-possible" style="display: none">Item is available for request</div>
<div role="alert" class="alert alert-warning" id="request-notpossible" style="display: none">
  Item cannot be requested
  <div id="localholdings" style="display:none"></div>
  <div id="errormessage" style="display:none"></div>
</div>
<form method="POST" action="[% here %]" id="create_form">
  [% INCLUDE 'csrf-token.inc' %]
  <fieldset class="rows">
    <legend>Enter metadata</legend>
    <input name="stage" id="stage" value="validate" type="hidden"/>
    <input name="method" id="method" value="create" type="hidden"/>
    <input name="backend" id="backend" value="[% whole.value.other.backend %]" type="hidden"/>
    <ol>
      <li id="reprints_desk_field_title">
        <label class="reprints_desk_label" id="title_label" for="title">[% whole.field_map.0.label | html %]</label>
        <textarea type="text" name="title" id="title"/>[% whole.value.other.title %]</textarea>
      </li>
      <li id="reprints_desk_field_atitle">
        <label class="reprints_desk_label" id="atitle_label" for="atitle">[% whole.field_map.1.label | html %]</label>
        <textarea type="text" name="atitle" id="atitle"/>[% whole.value.other.atitle %]</textarea>
      </li>
      [% FOREACH field IN whole.field_map %]
      [% key = field.key %]
      [% IF !field.exclude %]
      <li id="reprints_desk_field_[% key %]">
        <label class="reprints_desk_label" id="[% key %]_label" for="[% key %]">[% field.label | html %]</label>
        <input type="text" name="[% key %]" id="[% key %]" value="[% whole.value.other.$key %]" />
        [% IF field.help %]
        ([% field.help %])
        [% END %]
      </li>
      [% END %]
      [% END %]
    </ol>
  </fieldset>
  <fieldset class="rows">
    <legend>Patron options</legend>
    <ol>
      <li>
        <label class="required" for="cardnumber">Card number, username or surname:</label>
        <input type="text" autocomplete="off" name="cardnumber" id="cardnumber" type="text"
           value="[% whole.value.other.cardnumber %]" />
      </li>
      <li>
        <label class="required" for="branchcode">Destination library:</label>
        <select id="branchcode" name="branchcode">
          [% FOREACH branch IN branches %]
          [% IF ( whole.value.other.branchcode == branch.branchcode ) %]
          <option value="[% branch.branchcode %]" selected="selected">[% branch.branchname %]</option>
          [% ELSE %]
          <option value="[% branch.branchcode %]">[% branch.branchname %]</option>
          [% END %]
          [% END %]
        </select>
      </li>
    </ol>
  </fieldset>
  <fieldset class="action">
    <p id="reprints_desk_warning" role="alert" class="alert alert-danger">
      "Card number, username or surname" must be completed. Either DOI or PubMed ID must be completed.
    </p>
    <input id="reprints_desk_submit" disabled type="submit" value="Make request"/>
    <a class="cancel" href="/cgi-bin/koha/ill/ill-requests.pl">Cancel</a>
  </fieldset>
</form>

[% END %]
<style>
  fieldset.rows label.reprints_desk_label {
    width: 19rem;
  }
  #reprints_desk_warnings {
    margin-bottom: 0;
  }
  .reprints_desk_hint {
   margin-left: 1em; 
  }
  .alert {
    margin-top: 20px;
  }
  #localholdings,
  #errormessage {
    margin-top: 1rem;
  }
  #localholdings ul {
    margin-top: 0.5rem;
  }
  #localholdings li {
    margin: 0.3rem 0;
  }
</style>
[% BLOCK backend_jsinclude %]
<script>
  // Require a username and branch selection
  document.addEventListener('DOMContentLoaded', function(){
      $('#reprints_desk_submit').click(function() {
          $('#create_form').submit();
          $(this).prop('disabled', true);
      });

      $('#create_form input[type=text]').keyup(function() {
          if (
              $('#create_form #cardnumber').val() == '' ||
              ( $('#create_form #pubmedid').val() == '' && $('#create_form #doi').val() == '' ) )
            {
              $('#reprints_desk_submit').prop('disabled', true);
              $('#reprints_desk_warning').css('visibility', 'visible');
          } else {
              $('#reprints_desk_submit').prop('disabled', false);
              $('#reprints_desk_warning').css('visibility', 'hidden');
          }
      });    

      /* Maintain patron autocomplete compatibility across versions */
      [% IF koha_version.major <= 22 && koha_version.minor < 11 %]
      $('#create_form #cardnumber').autocomplete({
          source: "/cgi-bin/koha/circ/ysearch.pl",
          minLength: 3,
          select: function( event, ui ) {
              var field = ui.item.cardnumber;
              $('#create_form #cardnumber').val(field)
              return false;
          }
      })
      .data( "ui-autocomplete" )._renderItem = function( ul, item ) {
          return $( "<li></li>" )
          .data( "ui-autocomplete-item", item )
          .append( "<a>" + item.surname + ", " + item.firstname + " (" + item.cardnumber + ") <small>" + item.address + " " + item.city + " " + item.zipcode + " " + item.country + "</small></a>" )
          .appendTo( ul );
      };
      [% ELSE %]
      patron_autocomplete(
        $('#create_form #cardnumber'),
        {
          'on-select-callback': function( event, ui ) {
            $("#create_form #cardnumber").val( ui.item.cardnumber );
            return false;
          }
        }
      );
      [% END %]
  });
  //]]>
</script>
[% END %]
