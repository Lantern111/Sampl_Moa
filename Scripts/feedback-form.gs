// Creates the Sampl Moa bug report form in your Google account, and emails each report to that account's Gmail.
//
// 1. Go to https://script.google.com, click New project, and replace the code there with this file.
// 2. Choose setUp in the toolbar, click Run, and allow the permissions it asks for.
// 3. Copy the two links from the Execution log. Running it again shows the same links without making a second form.
//
// Your address is looked up when a report arrives, so it doesn't appear in this file or on the form.

function setUp() {
  const properties = PropertiesService.getScriptProperties();

  if (!properties.getProperty('formLink')) {
    const form = FormApp.create('Sampl Moa 버그 신고 / Bug Report', true);
    form.setDescription(
      '문제가 생긴 상황을 알려 주세요. 계정이나 이름은 필요 없습니다.\n' +
      'Tell us what went wrong. You don\'t need an account or a name.'
    );
    form.setConfirmationMessage('보내 주셔서 감사합니다. / Thanks for letting us know.');

    form.addParagraphTextItem()
      .setTitle('어떤 문제가 있었나요? / What went wrong?')
      .setRequired(true);
    form.addParagraphTextItem()
      .setTitle('어떻게 하면 다시 생기나요? / How can it be reproduced?');
    const appVersion = form.addTextItem()
      .setTitle('앱 버전 / App version');
    const macOSVersion = form.addTextItem()
      .setTitle('macOS 버전 / macOS version');
    form.addTextItem()
      .setTitle('답장 받을 이메일 / Email for a reply')
      .setHelpText('답장이 필요할 때만 적어 주세요. / Only if you\'d like a reply.')
      .setValidation(FormApp.createTextValidation().requireTextIsEmail().build());

    // The app swaps these two placeholders for the real versions when it opens the form.
    const prefilledLink = form.createResponse()
      .withItemResponse(appVersion.createResponse('APP_VERSION'))
      .withItemResponse(macOSVersion.createResponse('MACOS_VERSION'))
      .toPrefilledUrl();

    ScriptApp.newTrigger('sendReportToGmail').forForm(form).onFormSubmit().create();

    properties.setProperties({ formLink: form.getPublishedUrl(), prefilledLink: prefilledLink });
  }

  Logger.log('Form link: ' + properties.getProperty('formLink'));
  Logger.log('Prefilled link: ' + properties.getProperty('prefilledLink'));
}

function sendReportToGmail(event) {
  const report = event.response.getItemResponses()
    .filter(function (answer) { return answer.getResponse(); })
    .map(function (answer) { return answer.getItem().getTitle() + '\n' + answer.getResponse(); })
    .join('\n\n');

  MailApp.sendEmail(Session.getEffectiveUser().getEmail(), 'Sampl Moa 버그 신고', report);
}
