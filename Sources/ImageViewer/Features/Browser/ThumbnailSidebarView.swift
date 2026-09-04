import AppKit
import ImageViewerCore
import SwiftUI

@MainActor
struct ThumbnailSidebarView: @preconcurrency View {
    @EnvironmentObject private var model: ImageViewerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("浏览")
                    .font(.headline)
                Spacer()
                if !model.assets.isEmpty {
                    Text("\(model.assets.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Picker("浏览模式", selection: $model.sidebarMode) {
                ForEach(SidebarMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .transaction { transaction in
                transaction.animation = nil
            }

            Divider()

            Group {
                switch model.sidebarMode {
                case .folder:
                    folderView
                case .thumbnails:
                    thumbnailsView
                case .gallery:
                    galleryView
                }
            }
        }
        // A live material across the full scrolling sidebar forces backdrop
        // recomposition for every scroll tick. The native window color keeps
        // the workbench visually consistent while leaving scrolling opaque.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var folderView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("当前文件夹", systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                if let directoryURL = model.directoryURL {
                    Text(directoryURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("打开图片以浏览所在文件夹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var thumbnailsView: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.assets) { asset in
                    ThumbnailRow(
                        asset: asset,
                        isSelected: asset.id == model.currentAsset?.id
                    ) {
                        model.select(asset: asset)
                    }
                }
            }
            .padding(8)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .overlay {
            if model.assets.isEmpty {
                Text("此文件夹没有图片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    private var galleryView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76), spacing: 6)],
                spacing: 6
            ) {
                ForEach(model.assets) { asset in
                    GalleryThumbnail(
                        asset: asset,
                        isSelected: asset.id == model.currentAsset?.id
                    ) {
                        model.select(asset: asset)
                    }
                }
            }
            .padding(8)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

@MainActor
private struct ThumbnailRow: @preconcurrency View {
    let asset: ImageAsset
    let isSelected: Bool
    let action: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                thumbnailView
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.filename)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(asset.dimensionsLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(5)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.75), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.filename)
        .accessibilityValue(asset.dimensionsLabel)
        .task(id: asset.id) {
            thumbnail = await ThumbnailService.shared.image(for: asset.url)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct GalleryThumbnail: @preconcurrency View {
    let asset: ImageAsset
    let isSelected: Bool
    let action: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                thumbnailView
                    .frame(height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(asset.filename)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(asset.dimensionsLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.filename)
        .accessibilityValue(asset.dimensionsLabel)
        .task(id: asset.id) {
            thumbnail = await ThumbnailService.shared.image(for: asset.url)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
