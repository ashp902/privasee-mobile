# Privasee Mobile

Privasee Mobile is a privacy-first iOS application that helps users identify and secure sensitive information stored in their camera roll.

The product is designed for users who want visibility into personal data exposure across their photo library without giving up control of their images. Privasee scans photos on-device, detects visible personally identifiable information, and allows the user to create privacy-protected replacements by blurring only the sensitive text.

## What the App Does

Privasee Mobile enables users to:

- scan recent photos in their camera roll for visible sensitive information
- detect content such as IDs, account numbers, card numbers, addresses, phone numbers, and similar personal data
- review flagged images in a simple visual threat feed
- inspect each flagged photo in a full-screen viewer
- blur and replace sensitive text locally
- resolve one image at a time or process all flagged images in bulk

## Why It Matters

Photos often contain screenshots, documents, cards, forms, and IDs that users forget are stored in their library. These images can expose highly sensitive information long after they were captured.

Privasee Mobile is built to reduce that risk while preserving user trust. The app is intentionally designed around a zero-knowledge model so that image content remains on the device.

## Core Privacy Promise

Privasee Mobile is built on three privacy principles:

- images never leave the device
- text extraction happens locally on-device
- image redaction happens locally on-device

Only OCR text is sent for classification. No raw image data is uploaded.

## How It Works

At a high level, the product works as follows:

1. The user grants access to their photo library.
2. The app scans accessible recent photos.
3. Text is extracted locally from each image using Apple’s native OCR capabilities.
4. The extracted text is evaluated for sensitive information.
5. Any risky photo is surfaced in the app’s threat feed.
6. The user can then blur the detected sensitive text and save a protected replacement.

## User Experience

The experience is structured around three main areas:

### Dashboard

The dashboard presents the user’s current privacy state, recent scan status, and high-level risk summary.

### Threats Feed

Flagged images appear in a photo-grid style interface that mirrors familiar iOS browsing behavior. Users can quickly review the images that require attention.

### Full-Screen Review

Each flagged image can be opened in a full-screen viewer. From there, the user can:

- blur and replace the image
- mark it as not sensitive
- review the detected sensitive findings

## Key Capabilities

- on-device photo scanning
- multiple sensitive findings per image
- selective redaction of sensitive text regions only
- persistent threat tracking across launches
- bulk secure-and-replace workflow
- limited photo-library access management

## Persistence and Lifecycle

Privasee Mobile keeps track of what has already been reviewed so that users do not repeatedly process the same content.

The app remembers:

- the last scan date
- which photos have already been handled
- which photos are still active threats
- scan totals and recent scan counts

This allows the product to reopen with active threats already visible and prevents previously resolved images from being scanned again.

## Limited Access Support

For users who grant limited Photos access, the app supports a controlled access flow. Rather than repeatedly interrupting the user with automatic system prompts, Privasee provides a dedicated Settings action that allows the user to update the current photo selection when they choose.

## Technology Approach

Privasee Mobile is built entirely with Apple-native frameworks and modern SwiftUI architecture. It uses:

- SwiftUI for the application interface
- Photos and PhotosUI for photo-library integration
- Vision for on-device OCR
- Core Image for local redaction
- local persistence for scan and threat state

## Positioning

Privasee Mobile is not a cloud photo scanner. It is a privacy product designed to help users reduce exposure inside their own library while keeping the most sensitive asset, the image itself, on-device.

Its value comes from combining:

- strong privacy guarantees
- clear threat visibility
- low-friction remediation
- familiar iOS-native interactions

## Summary

Privasee Mobile gives users a practical way to understand and reduce privacy risk in their photo library without sending their photos to an external service. It identifies sensitive text, surfaces risky images, and allows users to secure them locally in a fast, familiar mobile workflow.
