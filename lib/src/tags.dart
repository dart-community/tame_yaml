/// Core YAML tags understood by the fixed decoding profile.
enum YamlCoreTag {
  /// The core null tag.
  nullValue('tag:yaml.org,2002:null'),

  /// The core boolean tag.
  boolean('tag:yaml.org,2002:bool'),

  /// The core integer tag.
  integer('tag:yaml.org,2002:int'),

  /// The core floating-point tag.
  float('tag:yaml.org,2002:float'),

  /// The core string tag.
  string('tag:yaml.org,2002:str'),

  /// The core sequence tag.
  sequence('tag:yaml.org,2002:seq'),

  /// The core mapping tag.
  mapping('tag:yaml.org,2002:map');

  /// Creates a core YAML tag with its expanded [uri].
  const YamlCoreTag(this.uri);

  /// The expanded URI identifying this tag.
  final String uri;

  /// Returns the supported tag identified by [uri], or `null` if there is none.
  static YamlCoreTag? tryParse(String uri) => _byUri[uri];

  /// Supported tags indexed by their expanded URI.
  static final Map<String, YamlCoreTag> _byUri = {
    for (final tag in values) tag.uri: tag,
  };
}
