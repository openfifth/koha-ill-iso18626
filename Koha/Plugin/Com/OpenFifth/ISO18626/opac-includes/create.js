$('#create_form input[type=text]').keyup(function() {
    checkIDFields();
});
checkIDFields();
function checkIDFields(){
    if ( $('#create_form #pubmedid').val() == '' && $('#create_form #doi').val() == '' ){
        $('#reprints_desk_submit').prop('disabled', true);
        $('#reprints_desk_warning').show();
    } else {
        $('#reprints_desk_submit').prop('disabled', false);
        $('#reprints_desk_warning').hide();
    }
}
// Add the appropriate label for each input
function addLabels() {
    var selected = $('#type').val();
    Object.keys(fieldmap).forEach(function (key) {
        var label = typeof fieldmap[key].label === 'object' ?
            fieldmap[key].label[selected] :
            fieldmap[key].label;
        $('#' + key + '_label').text(label);
    });

};