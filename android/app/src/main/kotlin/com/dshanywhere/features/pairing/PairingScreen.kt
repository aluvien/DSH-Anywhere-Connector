package com.dshanywhere.features.pairing

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.dshanywhere.LocalAppModel
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHPairingCredential
import com.dshanywhere.core.protocol.DSHPairingLink
import com.dshanywhere.ui.theme.DSHColors
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors

/**
 * 1:1 port of ios/DSHAnywhere/Features/Pairing/PairingView.swift.
 */
@Composable
fun PairingScreen() {
    val model = LocalAppModel.current
    var showScanner by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxSize()
            .background(DSHColors.systemBackground())
            .statusBarsPadding()
            .imePadding(),
    ) {
        // pairingHeader: stable 44pt glass header (native bar hidden on iOS).
        Row(
            Modifier
                .fillMaxWidth()
                .background(DSHColors.systemBackground().copy(alpha = 0.96f))
                .padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Spacer(Modifier.size(44.dp))
            Spacer(Modifier.weight(1f))
            Text(
                "DSH Anywhere",
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = DSHColors.label(),
            )
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(44.dp))
        }

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.Top),
        ) {
            // Image(systemName: "macbook.and.iphone") 64pt light, tinted
            Icon(
                Icons.Filled.LaptopMac,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .padding(top = 24.dp)
                    .size(64.dp),
            )

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    DSHLocalization.string("Connect to DeepSeek Harness"),
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold,
                    color = DSHColors.label(),
                    textAlign = TextAlign.Center,
                )
                Text(
                    DSHLocalization.string(
                        "Run DSH Anywhere Connector on your Mac, then scan the pairing code it prints, " +
                            "or enter the machine details by hand.",
                    ),
                    fontSize = 16.sp,
                    color = DSHColors.secondaryLabel(),
                    textAlign = TextAlign.Center,
                )
            }

            BigTintedButton(
                icon = { Icon(Icons.Filled.QrCodeScanner, null, tint = Color.White) },
                text = DSHLocalization.string("Scan pairing code"),
                onClick = { showScanner = true },
            )

            // Divider "Or enter manually"
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    Modifier
                        .weight(1f)
                        .height(1.dp)
                        .background(DSHColors.secondaryLabel().copy(alpha = 0.22f)),
                )
                Text(
                    DSHLocalization.string("Or enter manually"),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = DSHColors.secondaryLabel(),
                )
                Box(
                    Modifier
                        .weight(1f)
                        .height(1.dp)
                        .background(DSHColors.secondaryLabel().copy(alpha = 0.22f)),
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                HappyField(
                    value = model.serverAddress,
                    onValueChange = { model.serverAddress = it },
                    placeholder = "https://dsh.example.com",
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
                HappyField(
                    value = model.machineID,
                    onValueChange = { model.machineID = it },
                    placeholder = DSHLocalization.string("Machine ID"),
                )
                HappyField(
                    value = model.pairingSecret,
                    onValueChange = { model.pairingSecret = it },
                    placeholder = DSHLocalization.string("Pairing code or secret"),
                    visualTransformation = PasswordVisualTransformation(),
                )
            }

            BigTintedButton(
                icon = {
                    if (model.isPairing) {
                        CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.Link, null, tint = Color.White)
                    }
                },
                text = DSHLocalization.string("Pair with Mac"),
                showText = !model.isPairing,
                onClick = { model.pair() },
                enabled = !model.isPairing && model.machineID.isNotEmpty() &&
                    DSHPairingCredential.detect(model.pairingSecret) != null &&
                    model.serverAddress.isNotEmpty(),
            )

            Text(
                DSHLocalization.string("Your API keys stay on your Mac."),
                fontSize = 13.sp,
                color = DSHColors.secondaryLabel(),
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }

    if (showScanner) {
        PairingScannerSheet(
            onAccept = { link ->
                model.serverAddress = link.relay
                model.machineID = link.machineId
                model.pairingSecret = when (val c = link.credential) {
                    is DSHPairingCredential.Secret -> c.value
                    is DSHPairingCredential.Code -> c.value
                }
                showScanner = false
                model.pair()
            },
            onDismiss = { showScanner = false },
        )
    }
}

/** borderedProminent + Capsule, 52pt tall, full width. */
@Composable
private fun BigTintedButton(
    icon: @Composable () -> Unit,
    text: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    showText: Boolean = true,
) {
    val background = if (enabled) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.primary.copy(alpha = 0.4f)
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .background(background, CircleShape)
            .clickable(enabled = enabled) { onClick() },
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon()
        if (showText) {
            Text(text, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** happyFieldStyle: plain field, 17pt, 16 inset, 52 tall, rounded 16 quiet bg. */
@Composable
private fun HappyField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    visualTransformation: androidx.compose.ui.text.input.VisualTransformation =
        androidx.compose.ui.text.input.VisualTransformation.None,
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = TextStyle(fontSize = 17.sp, color = DSHColors.label()),
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        keyboardOptions = keyboardOptions,
        visualTransformation = visualTransformation,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .background(DSHColors.secondarySystemBackground(), RoundedCornerShape(16.dp))
            .padding(horizontal = 16.dp),
        decorationBox = { inner ->
            Box(contentAlignment = Alignment.CenterStart, modifier = Modifier.fillMaxWidth()) {
                if (value.isEmpty()) {
                    Text(placeholder, fontSize = 17.sp, color = DSHColors.tertiaryLabel())
                }
                inner()
            }
        },
    )
}

/**
 * Camera sheet to scan the pairing QR (VisionKit DataScanner equivalent).
 * The scanner keeps scanning for foreign codes; a rejected payload only shows
 * the capsule message, matching the iOS handler's `false` return.
 */
@Composable
private fun PairingScannerSheet(onAccept: (DSHPairingLink) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var cameraGranted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    var rejectedCode by remember { mutableStateOf<String?>(null) }
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted -> cameraGranted = granted }
    DisposableEffect(Unit) {
        if (!cameraGranted) permissionLauncher.launch(Manifest.permission.CAMERA)
        onDispose {}
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .navigationBarsPadding(),
    ) {
        if (cameraGranted) {
            QrScannerPreview(
                onCode = { payload ->
                    val link = DSHPairingLink.parse(payload)
                    if (link == null) {
                        rejectedCode = payload
                        false
                    } else {
                        rejectedCode = null
                        onAccept(link)
                        true
                    }
                },
            )
        } else {
            // ContentUnavailableView("Camera unavailable", …)
            Column(
                Modifier
                    .fillMaxSize()
                    .padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
            ) {
                Icon(Icons.Filled.PhotoCamera, null, tint = Color.White, modifier = Modifier.size(48.dp))
                Text(
                    DSHLocalization.string("Camera unavailable"),
                    color = Color.White,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    DSHLocalization.string(
                        "Scanning needs a physical iPhone with an available camera. " +
                            "Enter the machine details by hand instead.",
                    ),
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 16.sp,
                    textAlign = TextAlign.Center,
                )
            }
        }

        // scannerHeader
        Row(
            Modifier
                .fillMaxWidth()
                .background(Color.Black.copy(alpha = 0.72f))
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(44.dp)
                    .background(DSHColors.thinMaterial(), CircleShape)
                    .border(0.75.dp, Color.White.copy(alpha = 0.2f), CircleShape)
                    .clickable { onDismiss() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Close, DSHLocalization.string("Cancel"), tint = Color.White, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.weight(1f))
            Text(
                DSHLocalization.string("Scan pairing code"),
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(44.dp))
        }

        rejectedCode?.let {
            Text(
                DSHLocalization.string("That is not a DSH Anywhere pairing code."),
                fontSize = 13.sp,
                color = Color.Black,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 24.dp)
                    .background(DSHColors.thinMaterial(), CircleShape)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            )
        }
    }
}

/** CameraX preview + ImageAnalysis → ML Kit QR decode, single-use latch after accept. */
@Composable
private fun QrScannerPreview(onCode: (String) -> Boolean) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    var accepted by remember { mutableStateOf(false) }
    val scanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
    }

    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }

    AndroidView(
        factory = { previewView },
        modifier = Modifier.fillMaxSize(),
    ) { view ->
        val provider = ProcessCameraProvider.getInstance(context).get()
        provider.unbindAll()
        val preview = Preview.Builder().build().also {
            it.setSurfaceProvider(view.surfaceProvider)
        }
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { useCase ->
                useCase.setAnalyzer(analysisExecutor) { proxy ->
                    if (accepted) {
                        proxy.close()
                        return@setAnalyzer
                    }
                    val image = proxy.image
                    if (image == null) {
                        proxy.close()
                        return@setAnalyzer
                    }
                    @Suppress("UnsafeOptInUsageError")
                    val input = InputImage.fromMediaImage(image, proxy.imageInfo.rotationDegrees)
                    scanner.process(input)
                        .addOnSuccessListener { barcodes ->
                            if (accepted) return@addOnSuccessListener
                            for (barcode in barcodes) {
                                val payload = barcode.rawValue ?: continue
                                if (onCode(payload)) {
                                    accepted = true
                                    break
                                }
                            }
                        }
                        .addOnCompleteListener { proxy.close() }
                }
            }
        provider.bindToLifecycle(
            lifecycleOwner,
            CameraSelector.DEFAULT_BACK_CAMERA,
            preview,
            analysis,
        )
    }

    DisposableEffect(Unit) {
        onDispose {
            providerSafeUnbind(context)
            analysisExecutor.shutdown()
            scanner.close()
        }
    }
}

private fun providerSafeUnbind(context: android.content.Context) {
    runCatching { ProcessCameraProvider.getInstance(context).get().unbindAll() }
}
