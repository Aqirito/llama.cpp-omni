import ComniDomain
import SwiftUI

struct ChatView: View {
  @Bindable var model: ChatViewModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      conversation
      composer
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .alert("Chat failed", isPresented: errorPresented) {
      Button("OK") {
        model.errorMessage = nil
      }
    } message: {
      Text(model.errorMessage ?? "Unknown error")
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("New conversation")
          .font(.headline)
        Text("MiniCPM-o 4.5")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Toggle("Thinking", isOn: $model.thinkingEnabled)
        .toggleStyle(.switch)
        .controlSize(.small)
      Toggle("Voice", isOn: $model.ttsEnabled)
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!model.hasReferenceVoice)
        .help("Add a reference voice before enabling spoken replies")
    }
    .padding(.horizontal, 20)
    .frame(height: 58)
  }

  private var conversation: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 18) {
          if model.messages.isEmpty {
            welcome
              .padding(.top, 90)
          } else {
            ForEach(model.messages) { message in
              messageRow(message)
                .id(message.id)
            }
          }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
      }
      .onChange(of: model.messages) { _, messages in
        guard let lastID = messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(lastID, anchor: .bottom)
        }
      }
    }
  }

  private var welcome: some View {
    VStack(spacing: 14) {
      Image(systemName: "bubble.left.and.text.bubble.right")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(.secondary)
      Text("How can I help?")
        .font(.title2.weight(.semibold))
      Text("Chat locally with text first. Images, audio, and video attachments are next.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }

  private func messageRow(_ message: ChatMessage) -> some View {
    HStack(alignment: .top, spacing: 10) {
      if message.role == .user {
        Spacer(minLength: 90)
      } else {
        BrandIcon(size: 28)
      }

      Group {
        if message.text.isEmpty && message.role == .assistant {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Thinking")
              .foregroundStyle(.secondary)
          }
        } else {
          Text(message.text)
            .textSelection(.enabled)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        message.role == .user
          ? AnyShapeStyle(Color.accentColor.opacity(0.16))
          : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .frame(maxWidth: 620, alignment: .leading)

      if message.role != .user {
        Spacer(minLength: 30)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var composer: some View {
    VStack(spacing: 8) {
      HStack(alignment: .bottom, spacing: 10) {
        Button {
        } label: {
          Image(systemName: "plus")
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(true)
        .help("Attachments are coming next")

        TextField(
          "Message Comni",
          text: $model.composer,
          axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .onSubmit {
          Task {
            await model.send()
          }
        }

        Button {
          Task {
            await model.send()
          }
        } label: {
          Image(systemName: "arrow.up")
            .fontWeight(.semibold)
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .disabled(
          model.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isGenerating
        )
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )

      Text(model.runtimeStatus)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: 760)
    .padding(.horizontal, 28)
    .padding(.bottom, 18)
    .frame(maxWidth: .infinity)
  }

  private var errorPresented: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil },
      set: { isPresented in
        if !isPresented {
          model.errorMessage = nil
        }
      }
    )
  }
}
