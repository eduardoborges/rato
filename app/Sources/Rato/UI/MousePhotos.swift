import AppKit

/// Foto do mouse vista de cima. A imagem é da Logitech e não vai no repositório nem no app: o Rato baixa do site dela
/// na primeira vez e guarda ao lado do aprendizado da bateria.
enum MousePhotos {
    /// PID → caminho da foto no site da Logitech.
    /// ponytail: só o G703. Para outro modelo, basta pôr aqui o PID e o caminho da foto de cima no site.
    static let paths: [Int: String] = [
        0x4086: "/content/dam/gaming/en/products/g703-hero/2025-update/g703-mouse-top-angle-gallery-1.png",
    ]

    static func load(pid: Int) async -> NSImage? {
        guard let path = paths[pid] else { return nil }
        let dir = backupRoot.deletingLastPathComponent()
        let file = dir.appendingPathComponent(String(format: "mouse-%04x.webp", pid))
        if let image = NSImage(contentsOf: file) { return image }
        // O CDN corta a borda transparente (e_trim) e reduz para 640 px de altura, que bastam numa tela Retina.
        guard let url = URL(string: "https://resource.logitechg.com/e_trim/h_640,c_limit,f_webp,q_90" + path),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }
}
