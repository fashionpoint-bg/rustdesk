import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';

class InstallPage extends StatefulWidget {
  const InstallPage({Key? key}) : super(key: key);

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _InstallPageState() {
    Get.put<DesktopTabController>(tabController);
    const label = "install";
    tabController.add(TabInfo(
        key: label,
        label: label,
        closable: false,
        page: _InstallPageBody(
          key: const ValueKey(label),
        )));
  }

  @override
  void dispose() {
    super.dispose();
    Get.delete<DesktopTabController>();
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
      enableResizeEdges: windowManagerEnableResizeEdges,
      child: Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: DesktopTab(controller: tabController)),
      ),
    );
  }
}

class _InstallPageBody extends StatefulWidget {
  const _InstallPageBody({Key? key}) : super(key: key);

  @override
  State<_InstallPageBody> createState() => _InstallPageBodyState();
}

class _InstallPageBodyState extends State<_InstallPageBody>
    with WindowListener {
  late final TextEditingController controller;
  final RxBool startmenu = true.obs;
  final RxBool desktopicon = true.obs;
  final RxBool printer = false.obs;
  final RxBool showProgress = false.obs;
  final RxBool btnEnabled = true.obs;
  // FashionPoint: the clinic edition's own page (fp_pair::installs_first): two steps that end at the code
  // from the FashionPoint profile, the stock defaults instead of the choices, and a message instead of
  // closing when nothing was installed.
  final bool _fpClinic = bind.isIncomingOnly();
  final RxBool _fpFailed = false.obs;

  // todo move to theme.
  final buttonStyle = OutlinedButton.styleFrom(
    textStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.normal),
    padding: EdgeInsets.symmetric(vertical: 15, horizontal: 12),
  );

  _InstallPageBodyState() {
    controller = TextEditingController(text: bind.installInstallPath());
    final installOptions = jsonDecode(bind.installInstallOptions());
    startmenu.value = installOptions['STARTMENUSHORTCUTS'] != '0';
    desktopicon.value = installOptions['DESKTOPSHORTCUTS'] != '0';
    printer.value = installOptions['PRINTER'] == '1';
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    gFFI.close();
    super.onWindowClose();
    windowManager.setPreventClose(false);
    windowManager.close();
  }

  InkWell Option(RxBool option, {String label = ''}) {
    return InkWell(
      // todo mouseCursor: "SystemMouseCursors.forbidden" or no cursor on btnEnabled == false
      borderRadius: BorderRadius.circular(6),
      onTap: () => btnEnabled.value ? option.value = !option.value : null,
      child: Row(
        children: [
          Obx(
            () => Checkbox(
              visualDensity: VisualDensity(horizontal: -4, vertical: -4),
              value: option.value,
              onChanged: (v) =>
                  btnEnabled.value ? option.value = !option.value : null,
            ).marginOnly(right: 8),
          ),
          Expanded(
            child: Text(translate(label)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_fpClinic) return _buildFpClinic(context);
    final double em = 13;
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    return Scaffold(
        backgroundColor: null,
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Installation'),
                  style: Theme.of(context).textTheme.headlineMedium),
              Row(
                children: [
                  Text('${translate('Installation Path')}:')
                      .marginOnly(right: 10),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      readOnly: true,
                      decoration: InputDecoration(
                        contentPadding: EdgeInsets.all(0.75 * em),
                      ),
                    ).workaroundFreezeLinuxMint().marginOnly(right: 10),
                  ),
                  Obx(
                    () => OutlinedButton.icon(
                      icon: Icon(Icons.folder_outlined, size: 16),
                      onPressed: btnEnabled.value ? selectInstallPath : null,
                      style: buttonStyle,
                      label: Text(translate('Change Path')),
                    ),
                  )
                ],
              ).marginSymmetric(vertical: 2 * em),
              Option(startmenu, label: 'Create start menu shortcuts')
                  .marginOnly(bottom: 7),
              Option(desktopicon, label: 'Create desktop icon')
                  .marginOnly(bottom: 7),
              Option(printer, label: 'Install {$appName} Printer'),
              Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDarkTheme
                        ? Color.fromARGB(135, 87, 87, 90)
                        : Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 32)
                          .marginOnly(right: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(translate('agreement_tip'))
                              .marginOnly(bottom: em),
                          InkWell(
                            hoverColor: Colors.transparent,
                            onTap: () => launchUrlString(
                                'https://rustdesk.com/privacy.html'),
                            child: Tooltip(
                              message: 'https://rustdesk.com/privacy.html',
                              child: Row(children: [
                                Icon(Icons.launch_outlined, size: 16)
                                    .marginOnly(right: 5),
                                Text(
                                  translate('End-user license agreement'),
                                  style: const TextStyle(
                                      decoration: TextDecoration.underline),
                                )
                              ]),
                            ),
                          ),
                        ],
                      )
                    ],
                  )).marginSymmetric(vertical: 2 * em),
              Row(
                children: [
                  Expanded(
                    // NOT use Offstage to wrap LinearProgressIndicator
                    child: Obx(() => showProgress.value
                        ? LinearProgressIndicator().marginOnly(right: 10)
                        : Offstage()),
                  ),
                  Obx(
                    () => OutlinedButton.icon(
                      icon: Icon(Icons.close_rounded, size: 16),
                      label: Text(translate('Cancel')),
                      onPressed:
                          btnEnabled.value ? () => windowManager.close() : null,
                      style: buttonStyle,
                    ).marginOnly(right: 10),
                  ),
                  Obx(
                    () => ElevatedButton.icon(
                      icon: Icon(Icons.done_rounded, size: 16),
                      label: Text(translate('Accept and Install')),
                      onPressed: btnEnabled.value ? install : null,
                      style: buttonStyle,
                    ),
                  ),
                  Offstage(
                    offstage: bind.installShowRunWithoutInstall(),
                    child: Obx(
                      () => OutlinedButton.icon(
                        icon: Icon(Icons.screen_share_outlined, size: 16),
                        label: Text(translate('Run without install')),
                        onPressed: btnEnabled.value
                            ? () => bind.installRunWithoutInstall()
                            : null,
                        style: buttonStyle,
                      ).marginOnly(left: 10),
                    ),
                  ),
                ],
              )
            ],
          ).paddingSymmetric(horizontal: 4 * em, vertical: 3 * em),
        ));
  }

  Widget _buildFpClinic(BuildContext context) {
    final double em = 13;
    const textStyle = TextStyle(fontSize: 15, height: 1.5);
    Widget step(String number, String text) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$number.', style: textStyle).marginOnly(right: 8),
            Expanded(child: Text(translate(text), style: textStyle)),
          ],
        ).marginOnly(bottom: em);
    return Scaffold(
        backgroundColor: null,
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('fp-install-title'),
                      style: Theme.of(context).textTheme.headlineMedium)
                  .marginOnly(bottom: 2 * em),
              step('1', 'fp-install-step-install'),
              step('2', 'fp-install-step-code'),
              Obx(() => _fpFailed.value
                  ? Text(translate('fp-install-failed'),
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              height: 1.5))
                      .marginOnly(top: em)
                  : const Offstage()),
              Row(
                children: [
                  Expanded(
                    child: Obx(() => showProgress.value
                        ? LinearProgressIndicator().marginOnly(right: 10)
                        : const Offstage()),
                  ),
                  Obx(
                    () => OutlinedButton.icon(
                      icon: Icon(Icons.close_rounded, size: 16),
                      label: Text(translate('Cancel')),
                      onPressed:
                          btnEnabled.value ? () => windowManager.close() : null,
                      style: buttonStyle,
                    ).marginOnly(right: 10),
                  ),
                  Obx(
                    () => ElevatedButton.icon(
                      icon: Icon(Icons.done_rounded, size: 16),
                      label: Text(translate('Install')),
                      onPressed: btnEnabled.value ? _fpInstall : null,
                      style: buttonStyle,
                    ),
                  ),
                ],
              ).marginOnly(top: 2 * em),
            ],
          ).paddingSymmetric(horizontal: 4 * em, vertical: 3 * em),
        ));
  }

  void _fpInstall() async {
    btnEnabled.value = false;
    showProgress.value = true;
    _fpFailed.value = false;
    String args = '';
    if (startmenu.value) args += ' startmenu';
    if (desktopicon.value) args += ' desktopicon';
    if (printer.value) args += ' printer';
    try {
      // Returns only when nothing was installed: once installed, this process exits.
      await bind.installFpInstall(options: args, path: controller.text);
    } catch (e) {
      debugPrint('FPRemote install: $e');
    }
    _fpFailed.value = true;
    btnEnabled.value = true;
    showProgress.value = false;
  }

  void install() {
    do_install() {
      btnEnabled.value = false;
      showProgress.value = true;
      String args = '';
      if (startmenu.value) args += ' startmenu';
      if (desktopicon.value) args += ' desktopicon';
      if (printer.value) args += ' printer';
      bind.installInstallMe(options: args, path: controller.text);
    }

    do_install();
  }

  void selectInstallPath() async {
    String? install_path = await FilePicker.platform
        .getDirectoryPath(initialDirectory: controller.text);
    if (install_path != null) {
      controller.text = join(install_path, await bind.mainGetAppName());
    }
  }
}
