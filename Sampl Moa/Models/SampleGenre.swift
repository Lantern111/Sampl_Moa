import Foundation

/// A music genre. `id` matches the genre tags in Splice's own data.
nonisolated struct SampleGenre: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Other ways people write or search for it, including in Korean.
    let aliases: [String]

    init(_ id: String, title: String? = nil, aliases: [String] = []) {
        self.id = id
        self.title = title ?? id.capitalized
        self.aliases = aliases
    }

    static func == (lhs: SampleGenre, rhs: SampleGenre) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static let all: [SampleGenre] = [
        .init("hip hop", aliases: ["hiphop", "힙합"]),
        .init("trap", aliases: ["트랩"]),
        .init("trap edm", title: "Trap EDM"),
        .init("drill", aliases: ["드릴"]),
        .init("uk drill", title: "UK Drill", aliases: ["영국 드릴"]),
        .init("boom bap", aliases: ["boombap", "붐뱁"]),
        .init("lo-fi hip hop", aliases: ["lofi", "로파이"]),
        .init("lo-fi", aliases: ["lofi", "로파이"]),
        .init("rage", aliases: ["레이지"]),
        .init("pluggnb", title: "PluggnB", aliases: ["plugg", "플러그앤비"]),
        .init("cloud rap", aliases: ["클라우드 랩"]),
        .init("rnb", title: "R&B", aliases: ["r&b", "r and b", "알앤비"]),
        .init("soul", aliases: ["소울"]),
        .init("neo soul", aliases: ["네오소울", "네오 소울"]),
        .init("future soul", aliases: ["퓨처 소울"]),
        .init("soul jazz", aliases: ["소울 재즈"]),
        .init("jazz", aliases: ["재즈"]),
        .init("funk", aliases: ["펑크", "펑키"]),
        .init("disco", aliases: ["디스코"]),
        .init("nu disco", aliases: ["누 디스코"]),
        .init("pop", aliases: ["팝"]),
        .init("k-pop", aliases: ["kpop", "케이팝"]),
        .init("synth-pop", aliases: ["synthpop", "신스팝"]),
        .init("city pop", aliases: ["citypop", "시티팝"]),
        .init("hyperpop", aliases: ["하이퍼팝"]),
        .init("dream pop", aliases: ["드림팝"]),
        .init("indie", aliases: ["인디"]),
        .init("indie pop", aliases: ["인디팝"]),
        .init("indie rock", aliases: ["인디록", "인디락"]),
        .init("indie dance", aliases: ["인디 댄스"]),
        .init("indie electronic", aliases: ["인디 일렉트로닉"]),
        .init("rock", aliases: ["록", "락"]),
        .init("folk", aliases: ["포크"]),
        .init("house", aliases: ["하우스"]),
        .init("tech house", aliases: ["테크하우스", "테크 하우스"]),
        .init("deep house", aliases: ["딥하우스", "딥 하우스"]),
        .init("future house", aliases: ["퓨처하우스", "퓨처 하우스"]),
        .init("bass house", aliases: ["베이스 하우스"]),
        .init("big room house", aliases: ["bigroom", "빅룸"]),
        .init("electro house", aliases: ["일렉트로 하우스"]),
        .init("melodic house", aliases: ["멜로딕 하우스"]),
        .init("progressive house", aliases: ["프로그레시브 하우스"]),
        .init("tropical house", aliases: ["트로피컬 하우스"]),
        .init("afro house", aliases: ["아프로 하우스"]),
        .init("french house", aliases: ["프렌치 하우스"]),
        .init("funky house", aliases: ["펑키 하우스"]),
        .init("acid house", aliases: ["애시드 하우스"]),
        .init("stutter house", aliases: ["스터터 하우스"]),
        .init("techno", aliases: ["테크노"]),
        .init("melodic techno", aliases: ["멜로딕 테크노"]),
        .init("hard techno", aliases: ["하드 테크노"]),
        .init("trance", aliases: ["트랜스"]),
        .init("progressive trance", aliases: ["프로그레시브 트랜스"]),
        .init("psy trance", aliases: ["psytrance", "싸이 트랜스"]),
        .init("edm", title: "EDM", aliases: ["이디엠"]),
        .init("electronic", aliases: ["일렉트로닉"]),
        .init("electronica", aliases: ["일렉트로니카"]),
        .init("dubstep", aliases: ["덥스텝"]),
        .init("tearout dubstep", aliases: ["티어아웃"]),
        .init("riddim dubstep", aliases: ["리딤"]),
        .init("deep dubstep"),
        .init("drum and bass", title: "Drum & Bass", aliases: ["dnb", "d&b", "drum & bass", "드럼앤베이스", "드럼 앤 베이스"]),
        .init("jungle", aliases: ["정글"]),
        .init("breakbeat", aliases: ["브레이크비트"]),
        .init("breakcore", aliases: ["브레이크코어"]),
        .init("uk garage", title: "UK Garage", aliases: ["ukg", "garage", "개러지", "유케이 개러지"]),
        .init("speed garage", aliases: ["스피드 개러지"]),
        .init("future garage", aliases: ["퓨처 개러지"]),
        .init("grime", aliases: ["그라임"]),
        .init("jersey club", aliases: ["저지클럽", "저지 클럽"]),
        .init("baltimore club", aliases: ["볼티모어 클럽"]),
        .init("miami bass", aliases: ["마이애미 베이스"]),
        .init("bass music", aliases: ["베이스 뮤직"]),
        .init("future bass", aliases: ["퓨처베이스", "퓨처 베이스"]),
        .init("color bass", aliases: ["컬러 베이스"]),
        .init("leftfield bass"),
        .init("dancehall", aliases: ["댄스홀"]),
        .init("reggae", aliases: ["레게"]),
        .init("reggaeton", aliases: ["레게톤"]),
        .init("afrobeat", aliases: ["아프로비트"]),
        .init("afropop & afrobeats", aliases: ["afrobeats", "아프로비츠", "아프로팝"]),
        .init("afro latin", aliases: ["아프로 라틴"]),
        .init("afro tech", aliases: ["아프로 테크"]),
        .init("amapiano", aliases: ["아마피아노"]),
        .init("synthwave", aliases: ["신스웨이브"]),
        .init("hardwave", aliases: ["하드웨이브"]),
        .init("hardstyle", aliases: ["하드스타일"]),
        .init("hard dance", aliases: ["하드 댄스"]),
        .init("rave", aliases: ["레이브"]),
        .init("ambient", aliases: ["앰비언트"]),
        .init("downtempo", aliases: ["다운템포"]),
        .init("chillout", aliases: ["chill", "칠아웃"]),
        .init("trip hop", aliases: ["triphop", "트립합"]),
        .init("idm", title: "IDM"),
        .init("experimental", aliases: ["실험"]),
        .init("cinematic", aliases: ["시네마틱", "영화"]),
        .init("orchestral", aliases: ["오케스트라"]),
        .init("game audio", aliases: ["게임"]),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Words like these turn up in file names that have nothing to do with music (`Bubble_Pop`, `Bar_House`),
    /// so they only count when they name a folder.
    private static let unreliableInFileNames: Set<String> = [
        "pop", "soul", "house", "funk", "rock", "jazz", "indie", "folk", "rave", "jungle", "rage", "drill", "trance",
        "experimental", "electronic", "ambient", "disco",
    ]

    /// Picks the genres out of Splice's tags, with the pack's main genre first.
    static func from(tags: [String], packGenre: String?) -> [SampleGenre] {
        var seen: Set<String> = []
        return ([packGenre].compactMap { $0 } + tags)
            .compactMap { byID[$0] }
            .filter { seen.insert($0.id).inserted }
    }

    /// For samples with no Splice data, finds genres named in the file name or the folders around it.
    static func guess(fileName: String, folders: [String]) -> [SampleGenre] {
        let nameText = normalizedWords(fileName)
        let folderText = normalizedWords(folders.joined(separator: " "))
        return all.filter { genre in
            let terms = [genre.id] + genre.aliases
            return terms.contains { term in
                folderText.contains(" \(term) ")
                    || (!unreliableInFileNames.contains(genre.id) && nameText.contains(" \(term) "))
            }
        }
    }

    private static func normalizedWords(_ text: String) -> String {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "&" || $0 == "-") }
        return " " + words.joined(separator: " ") + " "
    }
}
