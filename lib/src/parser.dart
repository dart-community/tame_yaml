import 'dart:collection';

import 'code_unit.dart';
import 'cursor.dart';
import 'diagnostic.dart';
import 'errors.dart';
import 'limits.dart';
import 'scalar.dart';
import 'span.dart';
import 'tags.dart';

/// The fallback diagnostic for invalid block-scalar syntax.
const String _invalidBlockScalarSyntax = 'Invalid block scalar.';

/// The fallback diagnostic for invalid directive syntax.
const String _invalidDirectiveSyntax = 'Invalid YAML directive.';

/// The fallback diagnostic for invalid flow-collection syntax.
const String _invalidFlowSyntax = 'Invalid flow collection.';

/// The fallback diagnostic for invalid indentation.
const String _invalidIndentation = 'Invalid YAML indentation.';

/// The diagnostic for a flow mapping entry that neither continues nor closes.
const String _expectedMappingSeparator = 'Expected "," or "}".';

/// The specification's maximum simple-key length, in Unicode characters.
const int _maximumSimpleKeyCharacters = 1024;

/// A constructed value paired with the metadata its parent production needs.
///
/// The subtype records which production built the node,
/// since [value] is `null` for every node kind once an error is deferred.
sealed class _BuiltNode {
  /// Records the [value] and the metadata every node kind carries.
  const _BuiltNode(
    this.value, {
    required this.nodeCount,
    required this.aliasDepth,
    required this.span,
  });

  /// The constructed value, or `null` while discarding.
  final Object? value;

  /// The number of nodes in this subtree, counting this one.
  ///
  /// Charged against the construction budget when an alias expands.
  final int nodeCount;

  /// The longest chain of alias expansions reached within this subtree.
  final int aliasDepth;

  /// The span of source the node was parsed from,
  /// including any anchor and tag written on it.
  final SourceSpan span;
}

/// A resolved scalar that retains the source text it was resolved from.
final class _BuiltScalar extends _BuiltNode {
  /// Records a scalar [value] resolved from [text].
  const _BuiltScalar(
    super.value, {
    required this.text,
    required this.style,
    required this.explicitTag,
    required super.nodeCount,
    required super.aliasDepth,
    required super.span,
  });

  /// The scalar's content, after any unescaping and line folding.
  ///
  /// Retained so a later tag can resolve the same text again.
  final String text;

  /// The style [text] was written in.
  final ScalarStyle style;

  /// The supported tag written on the node, if any.
  final YamlCoreTag? explicitTag;
}

/// A completed block or flow collection.
final class _BuiltCollection extends _BuiltNode {
  /// Records a collection of [kind] whose unmodifiable entries are [value].
  const _BuiltCollection(
    super.value, {
    required this.kind,
    required super.nodeCount,
    required super.aliasDepth,
    required super.span,
  });

  /// Whether the entries in [value] form a sequence or a mapping.
  final _CollectionKind kind;
}

/// An expanded alias, or a placeholder for one that couldn't be expanded.
final class _BuiltAlias extends _BuiltNode {
  /// Records an alias holding [value] copied from its anchor.
  const _BuiltAlias(
    super.value, {
    required super.nodeCount,
    required super.aliasDepth,
    required super.span,
  });
}

/// Anchor and tag properties collected before a node is parsed.
final class _NodeProperties {
  /// Creates a set of parsed node properties.
  const _NodeProperties({this.anchor, this.tagUri, this.start});

  /// The anchor declaration attached to the node, if one was parsed.
  final _Anchor? anchor;

  /// The expanded tag URI, if one was declared.
  final String? tagUri;

  /// The position where the first property began.
  final ParserMark? start;
}

/// An in-progress or completed anchor definition.
final class _Anchor {
  /// Creates an anchor declared at [span].
  _Anchor(this.span);

  /// The span containing the anchor declaration.
  final SourceSpan span;

  /// The anchored node, once its construction finishes.
  _BuiltNode? value;
}

/// A plain scalar retained as source marks until construction needs its text.
final class _PlainScalarDraft {
  /// Records the source bounds and properties of an unbuilt plain scalar.
  const _PlainScalarDraft(
    this.start,
    this.contentStart,
    this.contentEnd,
    this.properties,
  );

  /// The start of the scalar, including its properties.
  final ParserMark start;

  /// The start of the scalar content.
  final ParserMark contentStart;

  /// The end of the first content segment.
  final ParserMark contentEnd;

  /// The properties attached to the scalar.
  final _NodeProperties properties;
}

/// A parsed mapping key and value pair, with the key prepared for storage.
typedef _NodePair = ({_BuiltNode key, _BuiltNode value, String? preparedKey});

/// The entries a mapping has collected so far.
///
/// Recording the key nodes in source order lets a duplicate
/// point back at the first declaration
/// without hashing every key a second time.
final class _MappingEntries {
  /// The value recorded under each key.
  final Map<String, Object?> values = <String, Object?>{};

  /// The recorded key nodes, in source order.
  final List<_BuiltNode> keys = <_BuiltNode>[];

  /// Whether a pair was already recorded under [key].
  bool contains(String key) => values.containsKey(key);

  /// Returns the node that first declared [key], if one did.
  ///
  /// Scanning is confined to the error path:
  /// the duplicate it reports is deferred,
  /// and every later key is discarded rather than looked up.
  _BuiltNode? firstDeclaring(String key) {
    for (final node in keys) {
      if (node.value == key) return node;
    }
    return null;
  }
}

/// The components and source position of a `%YAML` version directive.
typedef _VersionDirective = ({String major, String minor, ParserMark start});

/// The trailing-line-break policy of a block scalar header.
enum _BlockScalarChomping {
  /// Preserves one final line break.
  clip,

  /// Removes all final line breaks.
  strip,

  /// Preserves all final line breaks.
  keep,
}

/// A collection kind paired with the core tag it resolves to.
///
/// Each constant's [name] is the word used to describe it in diagnostics.
enum _CollectionKind {
  /// A block or flow sequence.
  sequence(YamlCoreTag.sequence),

  /// A block or flow mapping.
  mapping(YamlCoreTag.mapping);

  /// Creates a collection kind associated with [tag].
  const _CollectionKind(this.tag);

  /// The only core tag a collection of this kind can be given.
  final YamlCoreTag tag;
}

/// Incrementally folds and chomps a block scalar without retaining its lines.
final class _BlockScalarBuilder {
  /// Creates a builder that folds line breaks when [folded] is `true`.
  _BlockScalarBuilder({required this.folded});

  /// Whether ordinary line breaks fold to spaces.
  final bool folded;

  /// The accumulated scalar content.
  final StringBuffer _buffer = StringBuffer();

  /// Whether at least one source line has been added.
  bool _hasLines = false;

  /// Whether at least one added line contains content.
  bool _hasNonEmptyLine = false;

  /// Whether the previously added line was empty.
  bool _previousEmpty = true;

  /// Whether the previously added line was more indented.
  bool _previousMoreIndented = false;

  /// Whether the previously added line ended in a line break.
  bool _previousHasBreak = false;

  /// Whether the last nonempty line was more indented, if one exists.
  bool? _previousNonEmptyWasMoreIndented;

  /// Whether the final added line contains only whitespace.
  bool _finalLineIsBlank = true;

  /// Whether the final added line ended in a line break.
  bool _finalLineHasBreak = false;

  /// Adds one block-scalar source line to the accumulated content.
  ///
  /// [text] is the line with its indentation already removed.
  /// [moreIndented] keeps the breaks beside the line from folding, and
  /// [hasBreak] is `false` only for a final line that ran to the end of input.
  void addLine(
    String text, {
    required bool moreIndented,
    required bool hasBreak,
  }) {
    final empty = text.isEmpty;
    if (folded && _hasLines && _previousHasBreak) {
      // An ordinary break between two ordinary lines folds to a space.
      // Breaks beside an empty or more-indented line keep their newline,
      // except that a run of empty lines absorbs the break that ends it.
      final foldsToSpace =
          !_previousEmpty && !empty && !_previousMoreIndented && !moreIndented;
      final absorbedByEmptyLines =
          _previousEmpty &&
          !empty &&
          !moreIndented &&
          _previousNonEmptyWasMoreIndented == false;
      if (foldsToSpace) {
        _buffer.write(' ');
      } else if (!absorbedByEmptyLines) {
        _buffer.write('\n');
      }
    }

    _buffer.write(text);
    if (!folded && hasBreak) _buffer.write('\n');
    if (!empty) {
      _hasNonEmptyLine = true;
      _previousNonEmptyWasMoreIndented = moreIndented;
    }
    _hasLines = true;
    _previousEmpty = empty;
    _previousMoreIndented = moreIndented;
    _previousHasBreak = hasBreak;
    _finalLineIsBlank = _isBlankBlockScalarText(text);
    _finalLineHasBreak = hasBreak;
  }

  /// Applies [chomping] and returns the completed scalar content.
  String finish(_BlockScalarChomping chomping) {
    // Folding decides what a break becomes only once the next line is known,
    // so the break ending the last line is still owed here.
    if (folded && _hasLines && _previousHasBreak) {
      _buffer.write('\n');
    }
    final text = _buffer.toString();
    if (chomping == _BlockScalarChomping.keep) {
      // A trailing blank line contributed no break of its own to preserve.
      if (_hasLines && _finalLineIsBlank && !text.endsWith('\n')) {
        return '$text\n';
      }
      return text;
    }
    var end = text.length;
    while (end > 0 && text.codeUnitAt(end - 1) == CodeUnit.lineFeed) {
      end -= 1;
    }
    if (chomping == _BlockScalarChomping.strip) {
      return text.substring(0, end);
    }
    // Clipping keeps exactly one final break,
    // and only for content that had one:
    // an all-blank scalar clips away to nothing,
    // and a last line that ran to the end of input never had a break to keep.
    if (!_hasNonEmptyLine) return '';
    if (_hasLines && !_finalLineHasBreak && !_finalLineIsBlank) return text;
    return '${text.substring(0, end)}\n';
  }
}

/// A cursor-based parser that decodes YAML source
/// into the fixed profile's Dart values.
final class YamlParser {
  /// Creates a parser over [source].
  ///
  /// When [singleDocument] is `true`,
  /// a second document is rejected rather than parsed.
  YamlParser(
    String source, {
    required bool singleDocument,
  }) : this._(ParserCursor(source), singleDocument);

  /// Creates a parser from an initialized cursor and document-count policy.
  YamlParser._(this._cursor, this._singleDocument);

  /// The cursor over the source being parsed.
  final ParserCursor _cursor;

  /// Whether a second document must be rejected.
  final bool _singleDocument;

  /// Anchors declared in the current document.
  final _anchors = <String, _Anchor>{};

  /// Tag-handle bindings declared for the next document.
  final _tagDirectives = <String, String>{};

  /// The number of documents encountered in this stream.
  int _documentCount = 0;

  /// The number of nodes parsed in the current document.
  int _parsedNodes = 0;

  /// The number of aliases parsed in the current document.
  int _aliasCount = 0;

  /// The number of output nodes reserved in the current document.
  int _constructedNodes = 0;

  /// The current nested collection depth.
  int _collectionDepth = 0;

  /// A tab found in the indentation of the current content line.
  ParserMark? _indentationTab;

  /// The first deferred profile or construction failure.
  ///
  /// Deferring switches construction off while syntax scanning continues,
  /// so a later syntax error can retain its documented precedence.
  DecoderException? _deferredError;

  /// Whether construction has stopped after a deferred failure.
  bool get _discarding => _deferredError != null;

  /// Decodes the stream into an unmodifiable list of document values.
  ///
  /// Throws a [DecoderException] for any syntax, profile, or resource failure.
  List<Object?> decode() {
    if (_cursor.peek() == CodeUnit.byteOrderMark) {
      _cursor.readCodeUnit();
    }
    final documents = <Object?>[];

    _seekNextContentLine();
    while (!_cursor.isDone) {
      while (_isDocumentEndMarker) {
        _consumeDocumentEndMarker();
        _seekNextContentLine();
      }
      if (_cursor.isDone) break;

      final version = _parseDirectives();
      var inlineDocumentContent = false;
      if (_isDocumentStartMarker) {
        _consumeDocumentMarker();
        _cursor.skipInlineWhitespace();
        if (_cursor.peek() == CodeUnit.numberSign) _skipComment();
        if (_cursor.isBreak) {
          _cursor.readBreak();
          _seekNextContentLine();
        } else if (!_cursor.isDone) {
          // Content might follow an explicit start marker on the same line.
          inlineDocumentContent = true;
        }
      } else if (version != null || _tagDirectives.isNotEmpty) {
        // Directives bind to a document that "---" has to introduce.
        // Missing content is a plain syntax error,
        // while content that simply skipped the marker
        // is reported against the directives it followed.
        if (_cursor.isDone || _isDocumentEndMarker) {
          _syntax(
            'Expected "---".',
            _cursor.pointSpan(),
          );
        }
        _invalidDirective(
          'Expected "---".',
          _cursor.pointSpan(),
        );
      }

      _documentCount += 1;
      if (_singleDocument && _documentCount > 1) {
        _fail(
          YamlErrorCode.documentCount,
          'Multiple YAML documents found.',
          _cursor.pointSpan(),
          hint: 'Use yamlDecodeAll().',
        );
      }
      if (_documentCount > DecoderLimit.documentsPerStream) {
        _fail(
          YamlErrorCode.resourceLimit,
          'Stream exceeds ${DecoderLimit.documentsPerStream} documents.',
          _cursor.pointSpan(),
        );
      }
      if (version != null && (version.major != '1' || version.minor != '2')) {
        _fail(
          YamlErrorCode.unsupportedVersion,
          'Unsupported YAML version ${version.major}.${version.minor}.',
          _cursor.pointSpan(version.start),
          hint: 'Use %YAML 1.2.',
        );
      }

      _resetDocument();
      Object? value;
      _BuiltNode? root;
      if (_cursor.isDone || _isDocumentStartMarker || _isDocumentEndMarker) {
        value = null;
      } else {
        if (_isDirectiveIndicator) {
          _invalidDirective(
            'Directive not allowed here.',
            _cursor.pointSpan(),
          );
        }
        // A root node is nested inside nothing,
        // and a block mapping can't begin beside
        // the "---" that a same-line node follows.
        final rootIndent = _cursor.column;
        root = _parseBlockNode(
          -1,
          rootIndent,
          allowIndentlessSequence: true,
          allowCompactMapping: !inlineDocumentContent,
        );
        value = root.value;
      }

      // Reaching the document boundary proves that
      // no higher-priority parser error follows the deferred one.
      final deferred = _deferredError;
      if (deferred != null) throw deferred;
      documents.add(value);

      if (_isDocumentEndMarker) {
        _consumeDocumentEndMarker();
        _seekNextContentLine();
      } else if (!_cursor.isDone && !_isDocumentStartMarker) {
        if (_isDirectiveIndicator) {
          _invalidDirective(
            'Expected "..." first.',
            _cursor.pointSpan(),
          );
        }
        _syntax(
          'Content follows the document.',
          _unexpectedBlockContentSpan(root),
        );
      }
    }

    return List<Object?>.unmodifiable(documents);
  }

  /// Resets counters and state scoped to one document.
  void _resetDocument() {
    _parsedNodes = 0;
    _aliasCount = 0;
    _constructedNodes = 0;
    _collectionDepth = 0;
    _deferredError = null;
    _anchors.clear();
  }

  /// Parses the directive block preceding a document.
  _VersionDirective? _parseDirectives() {
    _VersionDirective? version;
    _tagDirectives.clear();
    while (_isDirectiveIndicator) {
      final start = _cursor.mark;
      _cursor.readCodeUnit();
      final nameStart = _cursor.mark;
      while (_isAlphaNumericHyphen(_cursor.peek())) {
        _cursor.readCodeUnit();
      }
      final name = _cursor.slice(nameStart);
      if (name.isEmpty) {
        _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
      }
      if (!_isInlineWhitespace(_cursor.peek())) {
        _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
      }
      _cursor.skipInlineWhitespace();

      if (name == 'YAML') {
        if (version != null) {
          _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
        }
        final major = _readVersionPart(start);
        if (!_cursor.consumeCodeUnit(CodeUnit.period)) {
          _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
        }
        final minor = _readVersionPart(start);
        version = (major: major, minor: minor, start: start);
      } else if (name == 'TAG') {
        final handle = _readTagHandle();
        if (!_isInlineWhitespace(_cursor.peek())) {
          _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
        }
        _cursor.skipInlineWhitespace();
        final prefix = _readDirectiveTagPrefix();
        if (prefix.isEmpty) {
          _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
        }
        if (_tagDirectives.containsKey(handle)) {
          _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
        }
        _tagDirectives[handle] = prefix;
      } else {
        _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
      }

      final commentSeparated = _isInlineWhitespace(_cursor.peek());
      _cursor.skipInlineWhitespace();
      _rejectByteOrderMark();
      if (_cursor.peek() == CodeUnit.numberSign) {
        if (!commentSeparated) {
          _invalidDirective(_invalidDirectiveSyntax, _cursor.pointSpan());
        }
        _skipComment();
      }
      if (!_cursor.isDone && !_cursor.isBreak) {
        _invalidDirective(_invalidDirectiveSyntax, _cursor.span(start));
      }
      if (_cursor.isBreak) _cursor.readBreak();
      _seekNextContentLine();
    }
    return version;
  }

  /// Reads and normalizes one numeric component of a version directive.
  ///
  /// A malformed component is reported against the whole directive,
  /// which begins at [directiveStart].
  String _readVersionPart(ParserMark directiveStart) {
    final start = _cursor.mark;
    while (CodeUnit.isAsciiDigit(_cursor.peek())) {
      _cursor.readCodeUnit();
    }
    if (_cursor.offset == start.offset) {
      _invalidDirective(
        _invalidDirectiveSyntax,
        _cursor.span(directiveStart),
      );
    }

    // Drop leading zeros, always keeping the final digit,
    // so that `1.0002` and `01.2` compare against
    // the supported version the same way `1.2` does.
    var first = start.offset;
    while (first < _cursor.offset - 1 &&
        _cursor.source.codeUnitAt(first) == CodeUnit.digit0) {
      first += 1;
    }

    // The part only ever reaches a diagnostic,
    // so an absurdly long run of digits is elided rather than echoed in full.
    final length = _cursor.offset - first;
    if (length <= 32) return _cursor.source.substring(first, _cursor.offset);
    return '${_cursor.source.substring(first, first + 31)}…';
  }

  /// Parses one block node at [indent], promoting it to a mapping if needed.
  ///
  /// The node must begin at [indent] and nest deeper than [parentIndent];
  /// otherwise it's absent, and an empty scalar stands in for it.
  /// [allowIndentlessSequence] exempts a sequence from that nesting rule,
  /// since one shares the indentation of the mapping it belongs to.
  ///
  /// [inheritedProperties] carries an anchor or tag written on an enclosing
  /// line, which applies to whichever node this builds.
  /// [countParsed] is `false` when the caller already charged the node
  /// against the parsing budget.
  ///
  /// A `false` [allowCompactMapping] rejects a block mapping that begins here,
  /// reporting it at [compactMappingErrorMark] when one is supplied.
  _BuiltNode _parseBlockNode(
    int parentIndent,
    int indent, {
    required bool allowIndentlessSequence,
    _NodeProperties? inheritedProperties,
    bool countParsed = true,
    bool allowCompactMapping = true,
    ParserMark? compactMappingErrorMark,
  }) {
    // A node begins exactly at [indent] and nests deeper than its parent,
    // unless it's an indentless sequence, which shares its parent's indent.
    if (_cursor.column != indent ||
        indent <= parentIndent &&
            !(allowIndentlessSequence &&
                indent == parentIndent &&
                _isBlockSequenceIndicator)) {
      return _emptyNode(_cursor.mark);
    }
    if (countParsed) _countParsedNode();

    /// Rejects a block mapping in a position that disallows a compact one.
    void checkCompactMappingAllowed() {
      if (!allowCompactMapping) {
        _syntax(
          'Block mapping not allowed.',
          _cursor.pointSpan(compactMappingErrorMark),
        );
      }
    }

    if (_isBlockSequenceIndicator &&
        (indent > parentIndent || allowIndentlessSequence)) {
      return _parseBlockSequence(indent, properties: inheritedProperties);
    }
    if (_isBlockMappingIndicator) {
      return _parseBlockMapping(indent, properties: inheritedProperties);
    }

    // Properties inherited from an enclosing line
    // apply to whichever node this call ends up building,
    // while a nested key or child node carries
    // only the properties written on its own line.
    final localProperties = _parseProperties();
    final properties = _mergeProperties(inheritedProperties, localProperties);
    if (_isBlockSequenceIndicator) {
      _validatePropertyMerge(inheritedProperties, localProperties);
      return _parseBlockSequence(indent, properties: properties);
    }

    if (_isMappingValueIndicator && properties.start != null) {
      checkCompactMappingAllowed();
      final key = _emptyNodeWithProperties(localProperties, _cursor.mark);
      return _parseBlockMapping(
        indent,
        firstKey: key,
        properties: inheritedProperties,
      );
    }

    if (_isBlockScalarIndicator) {
      _validatePropertyMerge(inheritedProperties, localProperties);
      return _parseBlockScalar(parentIndent, properties);
    }

    if (_atLineEnd) {
      // Nothing but properties and a comment remain on this line,
      // so the node itself is either nested below or absent entirely.
      _validatePropertyMerge(inheritedProperties, localProperties);
      final start = properties.start ?? _cursor.mark;
      _finishLine();
      _seekNextContentLine();
      if (_isAtNestedContent(
        parentIndent,
        allowIndentlessSequence: allowIndentlessSequence,
      )) {
        return _parseBlockNode(
          parentIndent,
          _cursor.column,
          allowIndentlessSequence: true,
          inheritedProperties: properties,
          countParsed: false,
        );
      }
      return _buildScalar(
        '',
        ScalarStyle.plain,
        properties,
        start,
        start,
      );
    }

    if (_isPlainStart(_cursor.peek(), flow: false)) {
      // Only a following ":" distinguishes a plain scalar from a mapping key,
      // so scan the first line and look past it before deciding which to build.
      final draft = _scanPlainFirstLine(localProperties, flow: false);
      if (_skipToMappingValueIndicator()) {
        checkCompactMappingAllowed();
        _checkSimpleKey(draft.start, _cursor.mark);
        final key = _buildPlainDraft(draft);
        return _parseBlockMapping(
          indent,
          firstKey: key,
          properties: inheritedProperties,
        );
      }
      _validatePropertyMerge(inheritedProperties, localProperties);
      // Properties written on an enclosing line sit before the scanned content,
      // so the draft is rebuilt to start at them and to carry the merged set.
      final scalarDraft = inheritedProperties == null
          ? draft
          : _PlainScalarDraft(
              properties.start ?? draft.start,
              draft.contentStart,
              draft.contentEnd,
              properties,
            );
      final scalar = _finishPlainScalar(
        scalarDraft,
        parentIndent,
        flow: false,
      );
      _finishLine();
      _seekNextContentLine();
      return scalar;
    }

    var node = _parseFlowNode(
      localProperties,
      parentIndent,
      keyContext: false,
    );
    if (_skipToMappingValueIndicator()) {
      checkCompactMappingAllowed();
      _checkSimpleKeySpan(node.span, _cursor.mark);
      return _parseBlockMapping(
        indent,
        firstKey: node,
        properties: inheritedProperties,
      );
    }
    if (inheritedProperties != null) {
      _validatePropertyMerge(inheritedProperties, localProperties);
      node = _applyProperties(node, properties);
    }
    _finishLine();
    _seekNextContentLine();
    return node;
  }

  /// Whether the cursor sits on block content nested inside [indent].
  ///
  /// A sequence indicator at [indent] itself nests
  /// when [allowIndentlessSequence] is `true`,
  /// since such a sequence shares its parent's indentation.
  bool _isAtNestedContent(
    int indent, {
    required bool allowIndentlessSequence,
  }) =>
      !_cursor.isDone &&
      !_isDocumentStartMarker &&
      !_isDocumentEndMarker &&
      (_cursor.column > indent ||
          allowIndentlessSequence &&
              _cursor.column == indent &&
              _isBlockSequenceIndicator);

  /// Rebuilds the positional portion of a mark from the start of [span],
  /// or from its end when [end] is `true`.
  ParserMark _markFromSpan(SourceSpan span, {required bool end}) =>
      // These synthetic marks are used for spans, never character distances.
      end
      ? ParserMark(span.endOffset, span.endLine, span.endColumn, 0)
      : ParserMark(span.startOffset, span.startLine, span.startColumn, 0);

  /// Enters a collection, reporting an overly deep one at [start].
  void _enterCollection(ParserMark start) {
    if (_collectionDepth >= DecoderLimit.nestingDepth) {
      _fail(
        YamlErrorCode.resourceLimit,
        'Document exceeds nesting depth ${DecoderLimit.nestingDepth}.',
        _cursor.pointSpan(start),
      );
    }
    _collectionDepth += 1;
  }

  /// Leaves the innermost collection.
  void _leaveCollection() => _collectionDepth -= 1;

  /// Parses at most one anchor and one tag property in either order.
  _NodeProperties _parseProperties() {
    _Anchor? anchor;
    String? tagUri;
    ParserMark? start;

    while (true) {
      final codeUnit = _cursor.peek();
      if (codeUnit != CodeUnit.ampersand &&
          codeUnit != CodeUnit.exclamationMark) {
        break;
      }
      start ??= _cursor.mark;
      if (codeUnit == CodeUnit.ampersand) {
        if (anchor != null) {
          _syntax('Duplicate anchor property.', _cursor.pointSpan());
        }
        final anchorStart = _cursor.mark;
        _cursor.readCodeUnit();
        final name = _readAnchorName(anchorStart, '&');
        // Registered before its node is built,
        // so an alias reached while that node is still being parsed
        // finds a valueless anchor and is caught as recursive.
        // A redeclared name shadows the earlier one from here on.
        final declaration = _Anchor(_cursor.span(anchorStart));
        anchor = declaration;
        _anchors[name] = declaration;
      } else {
        if (tagUri != null) {
          _syntax('Duplicate tag property.', _cursor.pointSpan());
        }
        tagUri = _readNodeTagUri();
      }

      // Without separation the node itself starts here,
      // except that a second property run together with the first
      // is a mistake worth naming.
      if (!_isInlineWhitespace(_cursor.peek())) {
        if (_cursor.peek() == CodeUnit.ampersand ||
            _cursor.peek() == CodeUnit.exclamationMark) {
          _syntax(
            'Separate node properties.',
            _cursor.pointSpan(),
          );
        }
        break;
      }
      _cursor.skipInlineWhitespace();
    }

    // Most nodes carry no properties at all.
    if (start == null) return const _NodeProperties();
    return _NodeProperties(anchor: anchor, tagUri: tagUri, start: start);
  }

  /// Combines properties inherited from a parent line with local properties.
  _NodeProperties _mergeProperties(
    _NodeProperties? inherited,
    _NodeProperties local,
  ) {
    if (inherited == null) return local;
    return _NodeProperties(
      anchor: local.anchor ?? inherited.anchor,
      tagUri: local.tagUri ?? inherited.tagUri,
      start: inherited.start ?? local.start,
    );
  }

  /// Rejects duplicate properties split across inherited and local sets.
  void _validatePropertyMerge(
    _NodeProperties? inherited,
    _NodeProperties local,
  ) {
    if (inherited == null) return;
    if (inherited.anchor != null && local.anchor != null) {
      _syntax(
        'Duplicate anchor property.',
        _cursor.pointSpan(local.start),
      );
    }
    if (inherited.tagUri != null && local.tagUri != null) {
      _syntax(
        'Duplicate tag property.',
        _cursor.pointSpan(local.start),
      );
    }
  }

  /// Reads one node tag and returns its expanded URI.
  String _readNodeTagUri() {
    final start = _cursor.mark;
    _cursor.readCodeUnit();
    if (_cursor.consumeCodeUnit(CodeUnit.lessThan)) {
      final uriStart = _cursor.mark;
      while (!_cursor.isDone &&
          _cursor.peek() != CodeUnit.greaterThan &&
          !_cursor.isBreak) {
        _rejectByteOrderMark();
        _cursor.readCodePoint();
      }
      if (!_cursor.consumeCodeUnit(CodeUnit.greaterThan)) {
        _syntax('Expected ">" after tag URI.', _cursor.span(start));
      }
      final encoded = _cursor.slice(uriStart, _markOffsetBy(-1));
      if (encoded.isEmpty) {
        _syntax("Tag URI can't be empty.", _cursor.span(start));
      }
      return _decodeTagText(encoded, _cursor.span(start), directive: false);
    }

    // Every remaining form expands a handle into the prefix it was bound to.
    final String prefix;
    final String suffix;
    if (_cursor.consumeCodeUnit(CodeUnit.exclamationMark)) {
      suffix = _readTagSuffix();
      if (suffix.isEmpty) {
        _syntax('Expected suffix after "!!".', _cursor.span(start));
      }
      prefix = _tagDirectives['!!'] ?? 'tag:yaml.org,2002:';
    } else {
      // A second "!" splits `!handle!suffix`.
      // Without one, the whole token is a suffix on the primary handle.
      final remainder = _readTagSuffix();
      final secondBang = remainder.indexOf('!');
      if (secondBang < 0) {
        prefix = _tagDirectives['!'] ?? '!';
        suffix = remainder;
      } else {
        final handle = '!${remainder.substring(0, secondBang + 1)}';
        if (!_isValidNamedTagHandle(handle)) {
          _syntax('Invalid tag handle.', _cursor.span(start));
        }
        final bound = _tagDirectives[handle];
        if (bound == null) {
          _syntax(
            'Undefined tag handle ${quoteForDiagnostic(handle)}.',
            _cursor.span(start),
          );
        }
        prefix = bound;
        suffix = remainder.substring(secondBang + 1);
        if (suffix.isEmpty) {
          _syntax('Expected tag suffix.', _cursor.span(start));
        }
      }
    }
    final decoded = _decodeTagText(
      suffix,
      _cursor.span(start),
      directive: false,
    );
    return '$prefix$decoded';
  }

  /// Reads the encoded suffix of a tag token.
  String _readTagSuffix() {
    final start = _cursor.mark;
    while (_isTagCharacter(_cursor.peek())) {
      _rejectByteOrderMark();
      _cursor.readCodePoint();
    }
    return _cursor.slice(start);
  }

  /// Reads a tag handle from a `%TAG` directive.
  String _readTagHandle() {
    final start = _cursor.mark;
    if (!_cursor.consumeCodeUnit(CodeUnit.exclamationMark)) {
      _invalidDirective(_invalidDirectiveSyntax, _cursor.pointSpan());
    }
    if (_cursor.consumeCodeUnit(CodeUnit.exclamationMark)) return '!!';

    final nameStart = _cursor.mark;
    while (_isAlphaNumericHyphen(_cursor.peek())) {
      _cursor.readCodeUnit();
    }
    if (_cursor.consumeCodeUnit(CodeUnit.exclamationMark)) {
      return _cursor.slice(start);
    }

    // A name was read but never closed, so this is neither `!` nor `!name!`.
    if (_cursor.offset != nameStart.offset) {
      _invalidDirective(
        _invalidDirectiveSyntax,
        _cursor.span(start),
      );
    }
    return '!';
  }

  /// Reads and decodes the prefix from a `%TAG` directive.
  String _readDirectiveTagPrefix() {
    final start = _cursor.mark;
    while (!_cursor.isDone &&
        !_cursor.isBreak &&
        !_isInlineWhitespace(_cursor.peek())) {
      _rejectByteOrderMark();
      _cursor.readCodePoint();
    }
    final encoded = _cursor.slice(start);
    return _decodeTagText(
      encoded,
      _cursor.span(start),
      directive: true,
    );
  }

  /// Validates and percent-decodes a tag URI fragment.
  String _decodeTagText(
    String encoded,
    SourceSpan span, {
    required bool directive,
  }) {
    /// Reports invalid tag encoding using the appropriate error category.
    Never invalidEncoding() {
      if (directive) {
        _invalidDirective(_invalidDirectiveSyntax, span);
      }
      _syntax('Invalid tag URI escape.', span);
    }

    // Check `%HH` structure here
    // so directive failures keep their distinct error category;
    // [Uri.decodeComponent] then validates the encoded UTF-8.
    for (var index = 0; index < encoded.length; index += 1) {
      if (encoded.codeUnitAt(index) != CodeUnit.percentSign) continue;
      if (index + 2 >= encoded.length ||
          !CodeUnit.isAsciiHexDigit(encoded.codeUnitAt(index + 1)) ||
          !CodeUnit.isAsciiHexDigit(encoded.codeUnitAt(index + 2))) {
        invalidEncoding();
      }
      index += 2;
    }
    try {
      return Uri.decodeComponent(encoded);
    } catch (error) {
      if (error is! FormatException && error is! ArgumentError) rethrow;
      invalidEncoding();
    }
  }

  /// Reads and validates the name following an anchor or alias [indicator].
  ///
  /// [start] marks the indicator itself,
  /// so a diagnostic covers the whole property.
  ///
  /// Scanning uses the specification's permissive character set
  /// and narrows the result afterwards, so a rejected name is reported whole
  /// rather than silently ending where this package's set does.
  String _readAnchorName(ParserMark start, String indicator) {
    final nameStart = _cursor.mark;
    while (_isAnchorCharacter(_cursor.peek())) {
      _rejectByteOrderMark();
      _cursor.readCodePoint();
    }
    final name = _cursor.slice(nameStart);
    if (name.isEmpty) {
      _syntax('Expected name after "$indicator".', _cursor.span(start));
    }
    if (!_isSupportedAnchorName(name)) {
      _fail(
        YamlErrorCode.unsupportedAnchorName,
        'Anchor name ${quoteForDiagnostic(name)} is unsupported.',
        _cursor.span(start),
        hint:
            'Start with an ASCII letter, digit, or "_"; '
            'then use those, ".", or "-".',
      );
    }
    return name;
  }

  /// Rejects a byte-order mark at the current position.
  void _rejectByteOrderMark() {
    if (_cursor.peek() != CodeUnit.byteOrderMark) return;
    _fail(
      YamlErrorCode.invalidCharacter,
      'Byte order mark not allowed.',
      _cursor.pointSpan(),
    );
  }

  /// Returns the mark [codeUnits] from the cursor,
  /// where a negative [codeUnits] moves backward.
  ///
  /// Every caller steps over single-code-unit ASCII characters on the current
  /// line, so each coordinate moves by [codeUnits] as well.
  ParserMark _markOffsetBy(int codeUnits) => ParserMark(
    _cursor.offset + codeUnits,
    _cursor.line,
    _cursor.column + codeUnits,
    _cursor.characterOffset + codeUnits,
  );

  /// Associates [value] with [anchor], when one was declared.
  void _finishAnchor(_Anchor? anchor, _BuiltNode value) {
    if (anchor != null) anchor.value = value;
  }

  /// Builds the empty scalar that stands in for a node omitted at [at].
  _BuiltScalar _emptyNode(ParserMark at) {
    _countParsedNode(at);
    return _buildScalar('', ScalarStyle.plain, const _NodeProperties(), at, at);
  }

  /// Builds an empty scalar for a node whose [properties] were already parsed.
  ///
  /// The properties were counted when they were parsed,
  /// so unlike [_emptyNode] this doesn't count the node again.
  _BuiltScalar _emptyNodeWithProperties(
    _NodeProperties properties,
    ParserMark at,
  ) => _buildScalar(
    '',
    ScalarStyle.plain,
    properties,
    properties.start ?? at,
    at,
  );

  /// Resolves the scalar [text] written in [style] between [start] and [end],
  /// then accounts for and anchors the node it builds.
  _BuiltScalar _buildScalar(
    String text,
    ScalarStyle style,
    _NodeProperties properties,
    ParserMark start,
    ParserMark end,
  ) {
    final span = _cursor.span(start, end);
    if (text.length > DecoderLimit.scalarCodeUnits) {
      _fail(
        YamlErrorCode.resourceLimit,
        'Scalar exceeds ${DecoderLimit.scalarCodeUnits} UTF-16 code units.',
        span,
      );
    }
    final tagUri = properties.tagUri;
    final tag = tagUri == null ? null : _recognizeTag(tagUri, span);
    final value = _resolveScalar(text, style, tag, span);
    _reserveConstructed(1, span);
    final built = _BuiltScalar(
      value,
      text: text,
      style: style,
      explicitTag: tag,
      nodeCount: 1,
      aliasDepth: 0,
      span: span,
    );
    _finishAnchor(properties.anchor, built);
    return built;
  }

  /// Rebuilds an already constructed nested node with all its [properties].
  _BuiltNode _applyProperties(
    _BuiltNode node,
    _NodeProperties properties,
  ) {
    final start = properties.start;
    if (start == null) return node;
    final end = _markFromSpan(node.span, end: true);
    final span = _cursor.span(start, end);
    final _BuiltNode result;
    switch (node) {
      case _BuiltScalar(:final text, :final style, :final explicitTag):
        // The caller passes the merged set,
        // so a tag declared on the nested line appears here
        // as well as in the already applied [explicitTag].
        // Recognizing it again is harmless: it resolves to the same tag,
        // only reported against the span
        // widened to cover the enclosing properties.
        final tagUri = properties.tagUri;
        final tag = tagUri == null ? explicitTag : _recognizeTag(tagUri, span);
        result = _BuiltScalar(
          _resolveScalar(text, style, tag, span),
          text: text,
          style: style,
          explicitTag: tag,
          nodeCount: node.nodeCount,
          aliasDepth: node.aliasDepth,
          span: span,
        );
      case _BuiltCollection(:final kind):
        _checkCollectionTag(properties.tagUri, kind, start, end);
        result = _BuiltCollection(
          node.value,
          kind: kind,
          nodeCount: node.nodeCount,
          aliasDepth: node.aliasDepth,
          span: span,
        );
      case _BuiltAlias():
        if (properties.tagUri != null || properties.anchor != null) {
          _syntax(
            "Alias can't have node properties.",
            span,
          );
        }
        return node;
    }
    _finishAnchor(properties.anchor, result);
    return result;
  }

  /// Returns the core tag the expanded [uri] names,
  /// or `null` if it names none.
  ///
  /// An unsupported tag is deferred, reported at [span],
  /// so syntax errors later in the document retain their precedence.
  YamlCoreTag? _recognizeTag(String uri, SourceSpan span) {
    final tag = YamlCoreTag.tryParse(uri);
    if (tag != null) return tag;
    _defer(
      DecoderException(
        YamlErrorCode.unsupportedTag,
        'Unsupported tag ${quoteForDiagnostic(uri)}.',
        span,
        hint: 'Use a YAML Core tag.',
      ),
    );
    return null;
  }

  /// Resolves a scalar while preserving syntax-error precedence.
  ///
  /// Returns `null` once any error is pending,
  /// so a discarded document never retains resolved values.
  Object? _resolveScalar(
    String text,
    ScalarStyle style,
    YamlCoreTag? tag,
    SourceSpan span,
  ) {
    if (_discarding) return null;
    try {
      return resolveScalar(text, style, tag, span);
    } on DecoderException catch (error) {
      _defer(error);
      return null;
    }
  }

  /// Finalizes, accounts for, and anchors a parsed sequence.
  ///
  /// [nodeCount] and [aliasDepth] aggregate the entries alone;
  /// the sequence itself is counted here.
  _BuiltCollection _finishSequence(
    List<Object?> values,
    _NodeProperties properties,
    ParserMark start,
    ParserMark end, {
    required int nodeCount,
    required int aliasDepth,
  }) {
    final span = _cursor.span(properties.start ?? start, end);
    _reserveConstructed(1, span);
    final built = _BuiltCollection(
      _discarding ? null : List<Object?>.unmodifiable(values),
      kind: _CollectionKind.sequence,
      nodeCount: nodeCount + 1,
      aliasDepth: aliasDepth,
      span: span,
    );
    _finishAnchor(properties.anchor, built);
    return built;
  }

  /// Finalizes, accounts for, and anchors a parsed mapping.
  ///
  /// [nodeCount] and [aliasDepth] aggregate the entries alone;
  /// the mapping itself is counted here.
  _BuiltCollection _finishMapping(
    Map<String, Object?> values,
    _NodeProperties properties,
    ParserMark start,
    ParserMark end, {
    required int nodeCount,
    required int aliasDepth,
  }) {
    final span = _cursor.span(properties.start ?? start, end);
    _reserveConstructed(1, span);
    final built = _BuiltCollection(
      // The entries were collected here and never escape,
      // so the view is as immutable as a copy would be.
      _discarding ? null : UnmodifiableMapView<String, Object?>(values),
      kind: _CollectionKind.mapping,
      nodeCount: nodeCount + 1,
      aliasDepth: aliasDepth,
      span: span,
    );
    _finishAnchor(properties.anchor, built);
    return built;
  }

  /// Checks an explicit [tagUri] written on a collection of [kind].
  ///
  /// Any diagnostic covers [start] through [end], or points at [start] alone.
  void _checkCollectionTag(
    String? tagUri,
    _CollectionKind kind,
    ParserMark start, [
    ParserMark? end,
  ]) {
    if (tagUri == null) return;
    final span = _cursor.span(start, end ?? start);
    final tag = _recognizeTag(tagUri, span);
    if (tag != null && tag != kind.tag) {
      _defer(DecoderException.invalidTaggedValue(tag, kind.name, span));
    }
  }

  /// Expands an alias into an independently immutable value tree.
  _BuiltAlias _parseAlias() {
    final start = _cursor.mark;
    _cursor.readCodeUnit();
    final name = _readAnchorName(start, '*');

    _aliasCount += 1;
    if (_aliasCount > DecoderLimit.aliasesPerDocument) {
      _fail(
        YamlErrorCode.resourceLimit,
        'Document exceeds ${DecoderLimit.aliasesPerDocument} aliases.',
        _cursor.span(start),
      );
    }
    final anchor = _anchors[name];
    if (anchor == null) {
      _fail(
        YamlErrorCode.undefinedAlias,
        'Alias ${quoteForDiagnostic(name)} has no anchor.',
        _cursor.span(start),
      );
    }
    final target = anchor.value;
    if (target == null) {
      _defer(
        DecoderException(
          YamlErrorCode.recursiveAlias,
          'Alias ${quoteForDiagnostic(name)} is recursive.',
          _cursor.span(start),
          relatedSpan: anchor.span,
          relatedLabel: 'Anchor declared here.',
        ),
      );
      return _BuiltAlias(
        null,
        nodeCount: 1,
        aliasDepth: 1,
        span: _cursor.span(start),
      );
    }
    final aliasDepth = target.aliasDepth + 1;
    if (aliasDepth > DecoderLimit.aliasExpansionDepth) {
      _defer(
        DecoderException(
          YamlErrorCode.resourceLimit,
          'Alias expansion exceeds depth ${DecoderLimit.aliasExpansionDepth}.',
          _cursor.span(start),
        ),
      );
    }
    // Reserve the complete expansion before allocating any copied collection.
    _reserveConstructed(target.nodeCount, _cursor.span(start));
    return _BuiltAlias(
      _discarding ? null : _deepCopy(target.value),
      nodeCount: target.nodeCount,
      aliasDepth: aliasDepth,
      span: _cursor.span(start),
    );
  }

  /// Deep-copies the collection portion of an already immutable value tree.
  ///
  /// The copy exists so a decoded document is a tree rather than a graph:
  /// two aliases of one anchor must never yield identical collection instances.
  Object? _deepCopy(Object? value) {
    if (value is List<Object?>) {
      return List<Object?>.unmodifiable(value.map(_deepCopy));
    }
    if (value is Map<String, Object?>) {
      return UnmodifiableMapView<String, Object?>({
        for (final MapEntry(:key, :value) in value.entries)
          key: _deepCopy(value),
      });
    }
    return value;
  }

  /// Whether [codeUnit] can begin a plain scalar,
  /// where [flow] tells whether that scalar would sit in a flow collection.
  bool _isPlainStart(int? codeUnit, {required bool flow}) {
    // Every caller passes the code unit at the cursor.
    if (_isBreakOrEnd(codeUnit) || _isInlineWhitespace(codeUnit)) return false;
    return switch (codeUnit) {
      // Indicators that can never open a plain scalar.
      CodeUnit.numberSign ||
      CodeUnit.ampersand ||
      CodeUnit.asterisk ||
      CodeUnit.exclamationMark ||
      CodeUnit.verticalBar ||
      CodeUnit.greaterThan ||
      CodeUnit.apostrophe ||
      CodeUnit.doubleQuote ||
      CodeUnit.percentSign ||
      CodeUnit.atSign ||
      CodeUnit.graveAccent ||
      CodeUnit.leftBracket ||
      CodeUnit.rightBracket ||
      CodeUnit.leftBrace ||
      CodeUnit.rightBrace ||
      CodeUnit.comma => false,
      // Indicators that open a plain scalar only when what follows
      // keeps them from being read as an indicator.
      CodeUnit.hyphenMinus ||
      CodeUnit.questionMark ||
      CodeUnit.colon => !_isPlainIndicatorBoundary(_cursor.peek(1), flow: flow),
      _ => true,
    };
  }

  /// Consumes one line of plain-scalar content, returning its trimmed end.
  ///
  /// Stops before the line break, before a comment, and before whichever
  /// indicators end a plain scalar in this context.
  /// The returned mark equals [contentStart]
  /// when the line contributed no content.
  ParserMark _scanPlainLine(ParserMark contentStart, {required bool flow}) {
    // Counting the trailing blanks,
    // instead of marking every content position,
    // keeps the scan free of per-character allocation.
    var trailingBlanks = 0;
    var previousWasBlank = false;
    while (true) {
      final codeUnit = _cursor.peek();
      if (_isBreakOrEnd(codeUnit)) break;
      if (flow && _isFlowDelimiter(codeUnit)) break;
      if (codeUnit == CodeUnit.colon &&
          _isPlainIndicatorBoundary(_cursor.peek(1), flow: flow)) {
        break;
      }
      if (codeUnit == CodeUnit.numberSign && previousWasBlank) break;
      if (codeUnit == CodeUnit.byteOrderMark) _rejectByteOrderMark();
      _cursor.readCodePoint();
      previousWasBlank = _isInlineWhitespace(codeUnit);
      trailingBlanks = previousWasBlank ? trailingBlanks + 1 : 0;
    }
    // Blanks are single ASCII code units on the line the scan started on,
    // so backing over them stays exact.
    // A line of only blanks backs all the way out to [contentStart].
    return _markOffsetBy(-trailingBlanks);
  }

  /// Scans the first line of a plain scalar, which mustn't be empty.
  ///
  /// Throws a [DecoderException] when the line contributes no content.
  _PlainScalarDraft _scanPlainFirstLine(
    _NodeProperties properties, {
    required bool flow,
  }) {
    final contentStart = _cursor.mark;
    final start = properties.start ?? contentStart;
    final contentEnd = _scanPlainLine(contentStart, flow: flow);
    if (contentEnd.offset == contentStart.offset) {
      _syntax('Expected a plain scalar.', _cursor.pointSpan(contentStart));
    }
    return _PlainScalarDraft(start, contentStart, contentEnd, properties);
  }

  /// Builds the first-line-only plain scalar represented by [draft].
  _BuiltScalar _buildPlainDraft(_PlainScalarDraft draft) {
    final text = _cursor.source.substring(
      draft.contentStart.offset,
      draft.contentEnd.offset,
    );
    return _buildScalar(
      text,
      ScalarStyle.plain,
      draft.properties,
      draft.start,
      draft.contentEnd,
    );
  }

  /// Consumes and folds every valid continuation line of a plain scalar.
  _BuiltScalar _finishPlainScalar(
    _PlainScalarDraft draft,
    int parentIndent, {
    required bool flow,
  }) {
    final first = _cursor.source.substring(
      draft.contentStart.offset,
      draft.contentEnd.offset,
    );
    // Most scalars stay on one line, so allocate only after finding a fold.
    StringBuffer? buffer;
    var finalEnd = draft.contentEnd;

    while (!_cursor.isDone) {
      // Only a line break can continue the scalar,
      // so a scalar that ends on its first line
      // never records where to fall back to.
      if (_cursor.peek() == CodeUnit.numberSign || !_cursor.isBreak) break;
      final lineEnd = _cursor.mark;

      // Look past the break and any blank lines
      // for a line indented more than the parent,
      // which is the only thing that can continue the scalar.
      _cursor.readBreak();
      var breakCount = 1;
      var continuation = false;
      while (!_cursor.isDone) {
        if (_cursor.column != 0) break;
        final indentationSpaces = _cursor.skipSpaces();
        while (_cursor.peek() == CodeUnit.tab) {
          _cursor.readCodeUnit();
        }
        if (_cursor.peek() == CodeUnit.numberSign) break;
        if (_cursor.isBreak) {
          _cursor.readBreak();
          breakCount += 1;
          continue;
        }
        continuation = flow
            ? indentationSpaces > parentIndent &&
                  !_isFlowDelimiter(_cursor.peek())
            : indentationSpaces > parentIndent &&
                  !_isDocumentStartMarker &&
                  !_isDocumentEndMarker;
        break;
      }

      // The lookahead consumed lines belonging to whatever follows,
      // so rewind to the break that ended the scalar
      // and let the caller resume there.
      if (!continuation) {
        _cursor.restore(lineEnd);
        break;
      }

      final segmentStart = _cursor.mark;
      final segmentEnd = _scanPlainLine(segmentStart, flow: flow);
      if (segmentEnd.offset == segmentStart.offset) {
        _cursor.restore(lineEnd);
        break;
      }
      buffer ??= StringBuffer(first);
      // A single break folds to a space;
      // each additional one contributes a newline,
      // since the run as a whole absorbs the first break.
      if (breakCount == 1) {
        buffer.write(' ');
      } else {
        buffer.write('\n' * (breakCount - 1));
      }
      buffer.write(
        _cursor.source.substring(segmentStart.offset, segmentEnd.offset),
      );
      finalEnd = segmentEnd;
    }

    return _buildScalar(
      buffer?.toString() ?? first,
      ScalarStyle.plain,
      draft.properties,
      draft.start,
      finalEnd,
    );
  }

  /// Parses one scalar, alias, or collection in flow-compatible syntax.
  ///
  /// [keyContext] holds a quoted scalar to the simple-key rules,
  /// since one used as a key can neither span lines
  /// nor exceed the key length limit.
  _BuiltNode _parseFlowNode(
    _NodeProperties properties,
    int parentIndent, {
    required bool keyContext,
  }) {
    final codeUnit = _cursor.peek();
    if (codeUnit == CodeUnit.asterisk) {
      if (properties.start != null) {
        _syntax(
          "Alias can't have properties.",
          _cursor.pointSpan(),
        );
      }
      return _parseAlias();
    }
    if (codeUnit == CodeUnit.leftBracket) {
      return _parseFlowSequence(properties, parentIndent);
    }
    if (codeUnit == CodeUnit.leftBrace) {
      return _parseFlowMapping(properties, parentIndent);
    }
    if (codeUnit == CodeUnit.apostrophe || codeUnit == CodeUnit.doubleQuote) {
      return _parseQuotedScalar(
        properties,
        parentIndent,
        keyContext: keyContext,
      );
    }
    if (_isPlainStart(codeUnit, flow: true)) {
      final draft = _scanPlainFirstLine(properties, flow: true);
      return _finishPlainScalar(draft, parentIndent, flow: true);
    }
    _syntax('Expected a YAML node.', _cursor.pointSpan());
  }

  /// Parses a quoted scalar, allocating a buffer only for normalization.
  ///
  /// [keyContext] checks the scalar against the simple-key rules,
  /// which a scalar standing as a mapping key has to satisfy.
  _BuiltScalar _parseQuotedScalar(
    _NodeProperties properties,
    int parentIndent, {
    required bool keyContext,
  }) {
    final start = properties.start ?? _cursor.mark;
    final quote = _cursor.readCodeUnit();
    final contentStart = _cursor.mark;
    ParserMark? simpleEnd;
    StringBuffer? buffer;
    // Verbatim content accumulates as source runs starting here.
    // The buffer is allocated only once something has to be rewritten,
    // and each rewrite flushes the run before it and opens a new one.
    var segmentStart = contentStart;
    var multiline = false;

    while (true) {
      final codeUnit = _cursor.peek();
      if (codeUnit == null) break;
      if (codeUnit == quote) {
        // A doubled apostrophe is the single-quoted style's only escape.
        if (quote == CodeUnit.apostrophe &&
            _cursor.peek(1) == CodeUnit.apostrophe) {
          buffer ??= StringBuffer();
          buffer.write(
            _cursor.source.substring(segmentStart.offset, _cursor.offset),
          );
          buffer.write("'");
          _cursor.readCodeUnit();
          _cursor.readCodeUnit();
          segmentStart = _cursor.mark;
          continue;
        }
        simpleEnd = _cursor.mark;
        if (buffer != null) {
          buffer.write(
            _cursor.source.substring(segmentStart.offset, _cursor.offset),
          );
        }
        _cursor.readCodeUnit();
        break;
      }
      if (quote == CodeUnit.doubleQuote && codeUnit == CodeUnit.backslash) {
        buffer ??= StringBuffer();
        buffer.write(
          _cursor.source.substring(segmentStart.offset, _cursor.offset),
        );
        _cursor.readCodeUnit();
        // An escaped line break joins its lines directly,
        // contributing neither the folded space nor any newline.
        if (_cursor.isBreak) {
          multiline = true;
          _cursor.readBreak();
          _consumeQuotedContinuationIndent(parentIndent);
          while (_cursor.isBreak) {
            _cursor.readBreak();
            _consumeQuotedContinuationIndent(parentIndent);
          }
          segmentStart = _cursor.mark;
          continue;
        }
        buffer.write(_readDoubleQuotedEscape(_markOffsetBy(-1)));
        segmentStart = _cursor.mark;
        continue;
      }
      if (codeUnit == CodeUnit.lineFeed ||
          codeUnit == CodeUnit.carriageReturn) {
        multiline = true;
        buffer ??= StringBuffer();
        // Whitespace before a line break is never part of the folded content.
        var contentEnd = _cursor.offset;
        while (contentEnd > segmentStart.offset &&
            _isInlineWhitespace(_cursor.source.codeUnitAt(contentEnd - 1))) {
          contentEnd -= 1;
        }
        buffer.write(_cursor.source.substring(segmentStart.offset, contentEnd));
        var breakCount = 0;
        do {
          _cursor.readBreak();
          breakCount += 1;
          _consumeQuotedContinuationIndent(parentIndent);
        } while (_cursor.isBreak);
        if (breakCount == 1) {
          buffer.write(' ');
        } else {
          buffer.write('\n' * (breakCount - 1));
        }
        segmentStart = _cursor.mark;
        continue;
      }
      _cursor.readCodePoint();
    }

    if (simpleEnd == null) {
      _syntax('Expected a closing quote.', _cursor.pointSpan());
    }
    if (keyContext) {
      if (multiline) {
        _syntax(
          'Simple key spans lines.',
          _cursor.pointSpan(),
        );
      }
      _checkSimpleKey(start, _cursor.mark);
    }
    final text =
        buffer?.toString() ??
        _cursor.source.substring(contentStart.offset, simpleEnd.offset);
    return _buildScalar(
      text,
      quote == CodeUnit.apostrophe
          ? ScalarStyle.singleQuoted
          : ScalarStyle.doubleQuoted,
      properties,
      start,
      _cursor.mark,
    );
  }

  /// Consumes indentation before a continued quoted-scalar line.
  void _consumeQuotedContinuationIndent(int parentIndent) {
    if (_isDocumentStartMarker || _isDocumentEndMarker) {
      _syntax(
        'Document marker inside quoted scalar.',
        _cursor.pointSpan(),
      );
    }
    final indentationSpaces = _cursor.skipSpaces();
    _cursor.skipInlineWhitespace();
    if (!_cursor.isDone &&
        !_cursor.isBreak &&
        parentIndent >= 0 &&
        indentationSpaces <= parentIndent) {
      _syntax(
        _invalidIndentation,
        _cursor.pointSpan(),
      );
    }
  }

  /// Reads the escape sequence beginning at [escapeStart].
  String _readDoubleQuotedEscape(ParserMark escapeStart) {
    if (_cursor.isDone) {
      _syntax('Expected an escape sequence.', _cursor.pointSpan());
    }
    final codeUnit = _cursor.readCodeUnit();
    return switch (codeUnit) {
      CodeUnit.digit0 => '\u0000',
      CodeUnit.lowercaseA => '\u0007',
      CodeUnit.lowercaseB => '\b',
      CodeUnit.lowercaseT || CodeUnit.tab => '\t',
      CodeUnit.lowercaseN => '\n',
      CodeUnit.lowercaseV => '\u000B',
      CodeUnit.lowercaseF => '\f',
      CodeUnit.lowercaseR => '\r',
      CodeUnit.lowercaseE => '\u001B',
      CodeUnit.space => ' ',
      CodeUnit.doubleQuote => '"',
      CodeUnit.slash => '/',
      CodeUnit.backslash => '\\',
      CodeUnit.uppercaseN => '\u0085',
      CodeUnit.underscore => '\u00A0',
      CodeUnit.uppercaseL => '\u2028',
      CodeUnit.uppercaseP => '\u2029',
      CodeUnit.lowercaseX => _readHexEscape(2),
      CodeUnit.lowercaseU => _readHexEscape(4),
      CodeUnit.uppercaseU => _readHexEscape(8),
      _ => _syntax('Unknown escape sequence.', _cursor.pointSpan(escapeStart)),
    };
  }

  /// Reads a hexadecimal character escape containing [length] digits.
  String _readHexEscape(int length) {
    final start = _cursor.mark;
    var value = 0;
    for (var index = 0; index < length; index += 1) {
      final codeUnit = _cursor.peek();
      if (codeUnit == null || !CodeUnit.isAsciiHexDigit(codeUnit)) {
        _syntax('Expected $length hexadecimal digits.', _cursor.span(start));
      }
      value = value * 16 + CodeUnit.asciiHexDigitValue(_cursor.readCodeUnit());
    }
    if (value > CodeUnit.maximumCodePoint ||
        value >= CodeUnit.highSurrogateStart &&
            value <= CodeUnit.lowSurrogateEnd) {
      _syntax(
        "Escape isn't a Unicode scalar.",
        _cursor.span(start),
      );
    }
    return String.fromCharCode(value);
  }

  /// Checks the simple key the cursor scanned from [start] to [end]
  /// against the single-line and length limits.
  void _checkSimpleKey(ParserMark start, ParserMark end) {
    if (end.line != start.line) {
      _syntax(
        'Simple key spans lines.',
        _cursor.pointSpan(end),
      );
    }
    // The marks already counted the characters between them.
    _checkSimpleKeyLength(end.characterOffset - start.characterOffset, end);
  }

  /// Checks the simple key covered by [span],
  /// which the cursor has reached the [end] of.
  void _checkSimpleKeySpan(SourceSpan span, ParserMark end) {
    if (span.startLine != end.line) {
      _syntax(
        'Simple key spans lines.',
        _cursor.pointSpan(end),
      );
    }
    _checkSimpleKeyLength(_countKeyCharacters(span.startOffset, end), end);
  }

  /// Enforces the simple-key limit in Unicode characters, not UTF-16 units.
  void _checkSimpleKeyLength(int characters, ParserMark end) {
    if (characters > _maximumSimpleKeyCharacters) {
      _syntax(
        'Simple key exceeds $_maximumSimpleKeyCharacters Unicode characters.',
        _cursor.pointSpan(end),
      );
    }
  }

  /// Counts the Unicode characters between [startOffset] and [end].
  ///
  /// Counting stops once the simple-key limit is passed,
  /// so the result is only exact for keys short enough to be allowed.
  int _countKeyCharacters(int startOffset, ParserMark end) {
    var characters = 0;
    var offset = startOffset;
    while (offset < end.offset && characters <= _maximumSimpleKeyCharacters) {
      final codeUnit = _cursor.source.codeUnitAt(offset);
      offset += 1;
      if (CodeUnit.isHighSurrogate(codeUnit) &&
          offset < end.offset &&
          CodeUnit.isLowSurrogate(_cursor.source.codeUnitAt(offset))) {
        offset += 1;
      }
      characters += 1;
    }
    return characters;
  }

  /// Parses a literal or folded block scalar, including its header indicators.
  _BuiltScalar _parseBlockScalar(
    int parentIndent,
    _NodeProperties properties,
  ) {
    final start = properties.start ?? _cursor.mark;
    final folded = _cursor.readCodeUnit() == CodeUnit.greaterThan;
    var chomping = _BlockScalarChomping.clip;
    int? indentationIndicator;

    // The header holds at most one chomping and one indentation indicator,
    // in either order, so two passes cover every valid combination.
    for (var index = 0; index < 2; index += 1) {
      final codeUnit = _cursor.peek();
      if (codeUnit == CodeUnit.plusSign || codeUnit == CodeUnit.hyphenMinus) {
        if (chomping != _BlockScalarChomping.clip) {
          _syntax(
            _invalidBlockScalarSyntax,
            _cursor.span(start),
          );
        }
        chomping = codeUnit == CodeUnit.plusSign
            ? _BlockScalarChomping.keep
            : _BlockScalarChomping.strip;
        _cursor.readCodeUnit();
      } else if (codeUnit != null &&
          codeUnit >= CodeUnit.digit1 &&
          codeUnit <= CodeUnit.digit9) {
        if (indentationIndicator != null) {
          _syntax(
            _invalidBlockScalarSyntax,
            _cursor.span(start),
          );
        }
        indentationIndicator = codeUnit - CodeUnit.digit0;
        _cursor.readCodeUnit();
      } else {
        break;
      }
    }
    // Zero is never a valid indentation indicator,
    // and any further digit is a second one,
    // so a digit here always ends the header invalidly.
    if (CodeUnit.isAsciiDigit(_cursor.peek())) {
      _syntax(
        _invalidBlockScalarSyntax,
        indentationIndicator == null
            ? _cursor.span(start)
            : _cursor.pointSpan(),
      );
    }

    final hadWhitespace = _isInlineWhitespace(_cursor.peek());
    _cursor.skipInlineWhitespace();
    if (_cursor.peek() == CodeUnit.numberSign) {
      if (!hadWhitespace) {
        _syntax(
          _invalidBlockScalarSyntax,
          _cursor.pointSpan(),
        );
      }
      _skipComment();
    }
    if (!_cursor.isDone && !_cursor.isBreak) {
      _syntax(
        _invalidBlockScalarSyntax,
        _cursor.pointSpan(),
      );
    }
    if (_cursor.isBreak) _cursor.readBreak();

    final contentIndent = indentationIndicator == null
        ? _detectBlockScalarIndent(parentIndent)
        : parentIndent + indentationIndicator;
    final builder = _BlockScalarBuilder(folded: folded);
    var end = _cursor.mark;

    while (!_cursor.isDone) {
      final lineStart = _cursor.mark;
      if (_cursor.column != 0) {
        _syntax(_invalidBlockScalarSyntax, _cursor.pointSpan());
      }
      if (_isDocumentStartMarker || _isDocumentEndMarker) break;
      _cursor.skipSpaces();
      final indentation = _cursor.column;
      if (_cursor.peek() == CodeUnit.tab && indentation < contentIndent) {
        _syntax(
          _invalidIndentation,
          _cursor.pointSpan(),
        );
      }
      if (_cursor.isBreak) {
        // An empty line keeps only the whitespace past the content indent.
        // The indentation itself is structure rather than content.
        final extra = indentation > contentIndent
            ? _cursor.source.substring(
                lineStart.offset + contentIndent,
                _cursor.offset,
              )
            : '';
        _cursor.readBreak();
        builder.addLine(
          extra,
          moreIndented: false,
          hasBreak: true,
        );
        end = _cursor.mark;
        continue;
      }
      if (indentation < contentIndent) {
        _cursor.restore(lineStart);
        break;
      }

      // Indentation beyond the detected content indent belongs to the content,
      // so slicing from a fixed column preserves it without a second scan.
      final textStartOffset = lineStart.offset + contentIndent;
      while (true) {
        final codeUnit = _cursor.peek();
        if (_isBreakOrEnd(codeUnit)) break;
        if (codeUnit == CodeUnit.byteOrderMark) _rejectByteOrderMark();
        _cursor.readCodePoint();
      }
      final text = _cursor.source.substring(textStartOffset, _cursor.offset);
      final hasBreak = _cursor.isBreak;
      if (hasBreak) _cursor.readBreak();
      builder.addLine(
        text,
        // Only spaces are skipped as indentation,
        // so a line led by a tab is more indented
        // even though its column matches the content indent.
        moreIndented:
            indentation > contentIndent || _startsWithInlineWhitespace(text),
        hasBreak: hasBreak,
      );
      end = _cursor.mark;
    }

    final text = builder.finish(chomping);
    _seekNextContentLine();
    return _buildScalar(
      text,
      folded ? ScalarStyle.folded : ScalarStyle.literal,
      properties,
      start,
      end,
    );
  }

  /// Detects the content indentation of a block scalar nested in [baseIndent],
  /// without retaining any of its source lines.
  int _detectBlockScalarIndent(int baseIndent) {
    final saved = _cursor.mark;
    var detected = baseIndent + 1;
    var maximumBlankIndent = 0;
    var sawContent = false;
    var firstContent = saved;
    while (!_cursor.isDone) {
      _cursor.skipSpaces();
      final indentation = _cursor.column;
      if (_cursor.isBreak) {
        if (indentation > maximumBlankIndent) maximumBlankIndent = indentation;
        _cursor.readBreak();
        continue;
      }
      if (indentation > baseIndent) {
        detected = indentation;
        sawContent = true;
        firstContent = _cursor.mark;
      }
      break;
    }
    _cursor.restore(saved);
    // With no content line to measure, the blank lines set the indent,
    // so that none is treated as more indented than the scalar itself.
    if (!sawContent) {
      if (maximumBlankIndent > detected) detected = maximumBlankIndent;
    } else if (maximumBlankIndent > detected) {
      // A leading empty line indented past the first content line
      // would make the scalar's own indentation ambiguous.
      _syntax(
        _invalidBlockScalarSyntax,
        _cursor.pointSpan(firstContent),
      );
    }
    return detected;
  }

  /// Parses a block sequence at [indent].
  _BuiltCollection _parseBlockSequence(
    int indent, {
    _NodeProperties? properties,
  }) {
    properties ??= const _NodeProperties();
    final start = properties.start ?? _cursor.mark;
    _enterCollection(start);
    _checkCollectionTag(properties.tagUri, _CollectionKind.sequence, start);
    final values = <Object?>[];
    var nodeCount = 0;
    var aliasDepth = 0;
    var end = start;

    try {
      while (_cursor.column == indent && _isBlockSequenceIndicator) {
        final indicator = _cursor.mark;
        _cursor.readCodeUnit();
        var sawTab = false;
        while (_isInlineWhitespace(_cursor.peek())) {
          if (_cursor.peek() == CodeUnit.tab) sawTab = true;
          _cursor.readCodeUnit();
        }
        // A compact nested sequence takes its indentation
        // from the separation before it, which a tab can't establish.
        if (sawTab && _isBlockSequenceIndicator) {
          _syntax(
            'Separate "-" with whitespace.',
            _cursor.pointSpan(),
          );
        }
        _BuiltNode child;
        if (_atLineEnd) {
          _finishLine();
          _seekNextContentLine();
          if (_isAtNestedContent(indent, allowIndentlessSequence: false)) {
            child = _parseBlockNode(
              indent,
              _cursor.column,
              allowIndentlessSequence: false,
            );
          } else {
            child = _emptyNode(indicator);
          }
        } else {
          child = _parseBlockNode(
            indent,
            _cursor.column,
            allowIndentlessSequence: false,
          );
        }
        nodeCount += child.nodeCount;
        aliasDepth = _max(aliasDepth, child.aliasDepth);
        if (!_discarding) values.add(child.value);
        end = _markFromSpan(child.span, end: true);

        // The entry ended somewhere the enclosing production has to handle:
        // at a document boundary, at a shallower line,
        // or at a line that no longer begins an entry.
        // Only a deeper line has no owner and is an error.
        if (_cursor.isDone || _isDocumentStartMarker || _isDocumentEndMarker) {
          break;
        }
        if (_cursor.column < indent) break;
        if (_cursor.column == indent && !_isBlockSequenceIndicator) break;
        if (_cursor.column > indent) {
          _syntax(
            _invalidIndentation,
            _cursor.pointSpan(_indentationTab),
          );
        }
      }
    } finally {
      _leaveCollection();
    }
    return _finishSequence(
      values,
      properties,
      start,
      end,
      nodeCount: nodeCount,
      aliasDepth: aliasDepth,
    );
  }

  /// Parses a block mapping and validates each key before its value.
  _BuiltCollection _parseBlockMapping(
    int indent, {
    _BuiltNode? firstKey,
    _NodeProperties? properties,
  }) {
    properties ??= const _NodeProperties();
    final start =
        properties.start ??
        (firstKey == null
            ? _cursor.mark
            : _markFromSpan(firstKey.span, end: false));
    if (firstKey != null) _countParsedNode(start);
    _enterCollection(start);
    _checkCollectionTag(properties.tagUri, _CollectionKind.mapping, start);
    final entries = _MappingEntries();
    var nodeCount = 0;
    var aliasDepth = 0;
    var end = start;

    /// Records a parsed pair and updates its aggregate metadata.
    void record(_BuiltNode key, _BuiltNode value, String? preparedKey) {
      nodeCount += key.nodeCount + value.nodeCount;
      aliasDepth = _max(aliasDepth, _max(key.aliasDepth, value.aliasDepth));
      _storeMappingValue(entries.values, preparedKey, value);
      end = _markFromSpan(value.span, end: true);
    }

    /// Validates [key] before parsing and recording the value that follows it.
    void addPair(_BuiltNode key) {
      final preparedKey = _prepareMappingKey(key, entries: entries);
      record(key, _parseBlockMappingValue(indent), preparedKey);
    }

    try {
      if (firstKey != null) addPair(firstKey);

      while (!_cursor.isDone &&
          !_isDocumentStartMarker &&
          !_isDocumentEndMarker &&
          _cursor.column == indent) {
        if (_isDirectiveIndicator) {
          _invalidDirective(
            'Expected "..." first.',
            _cursor.pointSpan(),
          );
        }
        // An indentless sequence shares this mapping's indentation,
        // so a "-" here continues the enclosing node
        // rather than starting a key.
        if (_isBlockSequenceIndicator) break;
        if (_cursor.peek() == CodeUnit.questionMark &&
            _isBlankBreakOrEnd(_cursor.peek(1))) {
          final pair = _parseExplicitBlockPair(indent, entries: entries);
          record(pair.key, pair.value, pair.preparedKey);
          continue;
        }
        if (_isMappingValueIndicator) {
          addPair(_emptyNode(_cursor.mark));
          continue;
        }

        addPair(_parseBlockSimpleKey(indent));

        if (!_cursor.isDone &&
            !_isDocumentStartMarker &&
            !_isDocumentEndMarker &&
            _cursor.column > indent) {
          _syntax(
            _invalidIndentation,
            _cursor.pointSpan(_indentationTab),
          );
        }
      }
    } finally {
      _leaveCollection();
    }
    return _finishMapping(
      entries.values,
      properties,
      start,
      end,
      nodeCount: nodeCount,
      aliasDepth: aliasDepth,
    );
  }

  /// Parses a simple key in a block mapping at [indent].
  _BuiltNode _parseBlockSimpleKey(int indent) {
    final keyStart = _cursor.mark;
    _countParsedNode();
    final properties = _parseProperties();
    final _BuiltNode key;
    if (_isMappingValueIndicator && properties.start != null) {
      key = _emptyNodeWithProperties(properties, _cursor.mark);
    } else if (_isPlainStart(_cursor.peek(), flow: false)) {
      final draft = _scanPlainFirstLine(properties, flow: false);
      if (!_skipToMappingValueIndicator()) {
        _syntax(
          'Expected ":" after mapping key.',
          _expectedColonSpan(keyStart, _cursor.mark),
        );
      }
      _checkSimpleKey(keyStart, _cursor.mark);
      key = _buildPlainDraft(draft);
    } else if (_cursor.peek() == CodeUnit.apostrophe ||
        _cursor.peek() == CodeUnit.doubleQuote ||
        _cursor.peek() == CodeUnit.leftBracket ||
        _cursor.peek() == CodeUnit.leftBrace ||
        _cursor.peek() == CodeUnit.asterisk) {
      key = _parseFlowNode(properties, indent, keyContext: true);
      if (!_skipToMappingValueIndicator()) {
        _syntax(
          'Expected ":" after mapping key.',
          _cursor.span(keyStart),
        );
      }
      _checkSimpleKeySpan(key.span, _cursor.mark);
    } else {
      _syntax(
        'Expected mapping key.',
        properties.start == null
            ? _cursor.pointSpan()
            : _nextContentPointSpan(),
      );
    }
    return key;
  }

  /// Parses an explicitly indicated block mapping pair.
  _NodePair _parseExplicitBlockPair(
    int indent, {
    required _MappingEntries entries,
  }) {
    final indicator = _cursor.mark;
    final indicatorLine = _cursor.line;
    _cursor.readCodeUnit();
    final separatedByTab = _cursor.peek() == CodeUnit.tab;
    _cursor.skipInlineWhitespace();
    final _BuiltNode key;

    if (_atLineEnd) {
      _finishLine();
      _seekNextContentLine();
      if (_isAtNestedContent(indent, allowIndentlessSequence: true)) {
        key = _parseBlockNode(
          indent,
          _cursor.column,
          allowIndentlessSequence: true,
        );
      } else {
        key = _emptyNode(indicator);
      }
    } else {
      key = _parseExplicitBlockKeyInline(
        indent,
        allowCompactMapping: !separatedByTab,
      );
    }

    final preparedKey = _prepareMappingKey(key, entries: entries);
    final afterKey = _cursor.mark;
    _cursor.skipInlineWhitespace();
    // The ":" pairs with this key only where the key itself began
    // or at the mapping's own indentation;
    // anywhere else it belongs to a nested node.
    var hasValue =
        _isMappingValueIndicator &&
        (_cursor.line == indicatorLine || _cursor.column == indent);
    if (!hasValue) {
      // Otherwise the ":" might still be waiting on the next content line.
      _cursor.restore(afterKey);
      if (_atLineEnd) {
        _finishLine();
        _seekNextContentLine();
        hasValue = _cursor.column == indent && _isMappingValueIndicator;
      }
    }
    return (
      key: key,
      value: hasValue
          ? _parseBlockMappingValue(indent, allowCompactCollections: true)
          : _emptyNode(_cursor.mark),
      preparedKey: preparedKey,
    );
  }

  /// Parses an explicit block key that begins beside its indicator.
  ///
  /// [allowCompactMapping] is `false` when a tab
  /// separated the key from its "?", since a tab can't
  /// establish the indentation a nested collection would take.
  _BuiltNode _parseExplicitBlockKeyInline(
    int indent, {
    required bool allowCompactMapping,
  }) {
    final keyStart = _cursor.mark;
    _countParsedNode();
    final properties = _parseProperties();
    if (_atLineEnd) {
      return _emptyNodeWithProperties(properties, _cursor.mark);
    }
    if (_isBlockSequenceIndicator) {
      if (!allowCompactMapping) {
        _syntax(
          _invalidIndentation,
          _cursor.pointSpan(),
        );
      }
      return _parseBlockSequence(_cursor.column, properties: properties);
    }
    if (_isBlockMappingIndicator) {
      if (!allowCompactMapping) {
        _syntax(
          _invalidIndentation,
          _cursor.pointSpan(),
        );
      }
      return _parseBlockMapping(_cursor.column, properties: properties);
    }
    if (_isBlockScalarIndicator) {
      return _parseBlockScalar(indent, properties);
    }
    if (_isPlainStart(_cursor.peek(), flow: false)) {
      final keyIndent = _cursor.column;
      final draft = _scanPlainFirstLine(properties, flow: false);
      if (_skipToMappingValueIndicator()) {
        if (!allowCompactMapping) {
          _syntax(
            _invalidIndentation,
            _cursor.pointSpan(keyStart),
          );
        }
        final firstKey = _buildPlainDraft(draft);
        return _parseBlockMapping(keyIndent, firstKey: firstKey);
      }
      return _finishPlainScalar(draft, indent, flow: false);
    }
    return _parseFlowNode(properties, indent, keyContext: false);
  }

  /// Parses the value following a block mapping key at [indent].
  ///
  /// [allowCompactCollections] lets a sequence or mapping begin beside the
  /// ":", which only an explicit "?" pair permits.
  _BuiltNode _parseBlockMappingValue(
    int indent, {
    bool allowCompactCollections = false,
  }) {
    final indicator = _cursor.mark;
    _cursor.readCodeUnit();
    // A colon can immediately follow the indicator only in the `::` form
    // that [_isMappingValueIndicator] accepts at column zero,
    // where the second one is the whole of the value: the plain scalar ":".
    if (_cursor.peek() == CodeUnit.colon) {
      final scalarStart = _cursor.mark;
      _countParsedNode();
      _cursor.readCodeUnit();
      final value = _buildScalar(
        ':',
        ScalarStyle.plain,
        const _NodeProperties(),
        scalarStart,
        _cursor.mark,
      );
      _finishLine();
      _seekNextContentLine();
      return value;
    }
    var sawTab = false;
    while (_isInlineWhitespace(_cursor.peek())) {
      if (_cursor.peek() == CodeUnit.tab) sawTab = true;
      _cursor.readCodeUnit();
    }
    final valueStart = _cursor.mark;
    if (_atLineEnd) {
      _finishLine();
      _seekNextContentLine();
      if (_isAtNestedContent(indent, allowIndentlessSequence: true)) {
        // Only an indentless sequence can start at the mapping's own indent.
        if (_cursor.column == indent) {
          _countParsedNode();
          return _parseBlockSequence(indent);
        }
        return _parseBlockNode(
          indent,
          _cursor.column,
          allowIndentlessSequence: true,
        );
      }
      return _emptyNode(indicator);
    }
    if (_isBlockSequenceIndicator && (!allowCompactCollections || sawTab)) {
      _syntax(
        'Block sequence must start on a new line.',
        _cursor.pointSpan(),
      );
    }
    return _parseBlockNode(
      indent,
      _cursor.column,
      allowIndentlessSequence: true,
      allowCompactMapping: allowCompactCollections && !sawTab,
      compactMappingErrorMark: sawTab ? valueStart : null,
    );
  }

  /// Validates a mapping [key], returning the string to store it under,
  /// or `null` if it can't be used.
  ///
  /// The key is checked against and recorded in [entries],
  /// so that a later duplicate can point back at the first one.
  String? _prepareMappingKey(
    _BuiltNode key, {
    required _MappingEntries entries,
  }) {
    if (_discarding) return null;
    if (key case _BuiltScalar(
      style: ScalarStyle.plain,
      text: '<<',
      explicitTag: != YamlCoreTag.string,
    )) {
      _defer(
        DecoderException(
          YamlErrorCode.mergeKey,
          'Plain "<<" mapping key is unsupported.',
          key.span,
          hint: 'Quote "<<" for a literal key.',
        ),
      );
      return null;
    }
    final constructed = key.value;
    if (constructed is! String) {
      _defer(
        DecoderException(
          YamlErrorCode.nonStringKey,
          'Mapping key resolves to ${_typeName(constructed)}; expected '
          'String.',
          key.span,
          hint: 'Quote the key for a string.',
        ),
      );
      return null;
    }
    if (entries.contains(constructed)) {
      _defer(
        DecoderException(
          YamlErrorCode.duplicateKey,
          'Duplicate mapping key ${quoteForDiagnostic(constructed)}.',
          key.span,
          relatedSpan: entries.firstDeclaring(constructed)?.span,
          relatedLabel: 'First declared here.',
          hint: 'Remove or rename one key.',
        ),
      );
      return null;
    }
    entries.keys.add(key);
    return constructed;
  }

  /// Stores [value] under a previously validated [key], unless discarding.
  void _storeMappingValue(
    Map<String, Object?> values,
    String? key,
    _BuiltNode value,
  ) {
    if (!_discarding && key != null) values[key] = value.value;
  }

  /// Returns the name diagnostics use for [value]'s type.
  String _typeName(Object? value) => switch (value) {
    null => 'null',
    bool() => 'bool',
    int() => 'int',
    double() => 'double',
    List<Object?>() => 'sequence',
    Map<String, Object?>() => 'mapping',
    _ => 'value',
  };

  /// Parses a bracket-delimited flow sequence.
  _BuiltCollection _parseFlowSequence(
    _NodeProperties properties,
    int parentIndent,
  ) {
    final start = properties.start ?? _cursor.mark;
    _enterCollection(start);
    _checkCollectionTag(properties.tagUri, _CollectionKind.sequence, start);
    _cursor.readCodeUnit();
    final values = <Object?>[];
    var nodeCount = 0;
    var aliasDepth = 0;
    final ParserMark end;
    try {
      _skipFlowSeparation(parentIndent);
      if (!_cursor.consumeCodeUnit(CodeUnit.rightBracket)) {
        while (true) {
          final entry = _parseFlowSequenceEntry(parentIndent);
          nodeCount += entry.nodeCount;
          aliasDepth = _max(aliasDepth, entry.aliasDepth);
          if (!_discarding) values.add(entry.value);
          _skipFlowSeparation(parentIndent);
          if (_cursor.consumeCodeUnit(CodeUnit.rightBracket)) break;
          if (!_cursor.consumeCodeUnit(CodeUnit.comma)) {
            _syntax('Expected "," or "]".', _cursor.pointSpan());
          }
          // Checking again after the comma accepts a trailing one.
          _skipFlowSeparation(parentIndent);
          if (_cursor.consumeCodeUnit(CodeUnit.rightBracket)) break;
        }
      }
      end = _cursor.mark;
    } finally {
      _leaveCollection();
    }
    return _finishSequence(
      values,
      properties,
      start,
      end,
      nodeCount: nodeCount,
      aliasDepth: aliasDepth,
    );
  }

  /// Parses one value entry inside a flow sequence.
  _BuiltNode _parseFlowSequenceEntry(int parentIndent) {
    // A pair can begin with "?", with ":" for an empty key,
    // or with the key itself,
    // so all three openings are checked before the entry is read.
    if (_startsExplicitKey() ||
        _cursor.peek() == CodeUnit.colon &&
            _isPlainIndicatorBoundary(_cursor.peek(1), flow: true)) {
      _rejectPairInFlowSequence();
    }

    final value = _parseFlowChild(parentIndent);
    _skipFlowSeparation(parentIndent);
    if (_cursor.peek() == CodeUnit.colon) {
      _rejectPairInFlowSequence();
    }
    return value;
  }

  /// Whether a "?" opening an explicit mapping key begins at the cursor.
  bool _startsExplicitKey() =>
      _cursor.peek() == CodeUnit.questionMark &&
      _isFlowIndicatorBoundary(_cursor.peek(1));

  /// Rejects a mapping pair written directly as a flow sequence entry.
  Never _rejectPairInFlowSequence() => _fail(
    YamlErrorCode.unsupportedFlowEntry,
    'Flow sequence entry is a mapping pair.',
    _cursor.pointSpan(),
    hint: 'Enclose the pair in "{}".',
  );

  /// Parses a brace-delimited flow mapping.
  _BuiltCollection _parseFlowMapping(
    _NodeProperties properties,
    int parentIndent,
  ) {
    final start = properties.start ?? _cursor.mark;
    _enterCollection(start);
    _checkCollectionTag(properties.tagUri, _CollectionKind.mapping, start);
    _cursor.readCodeUnit();
    final entries = _MappingEntries();
    var nodeCount = 0;
    var aliasDepth = 0;
    final ParserMark end;
    try {
      _skipFlowSeparation(parentIndent);
      if (!_cursor.consumeCodeUnit(CodeUnit.rightBrace)) {
        while (true) {
          final explicit = _startsExplicitKey();
          if (explicit) {
            _cursor.readCodeUnit();
            _skipFlowSeparation(parentIndent);
          }
          final pair = _parseFlowPair(
            parentIndent,
            explicit: explicit,
            entries: entries,
          );
          nodeCount += pair.key.nodeCount + pair.value.nodeCount;
          aliasDepth = _max(
            aliasDepth,
            _max(pair.key.aliasDepth, pair.value.aliasDepth),
          );
          _storeMappingValue(entries.values, pair.preparedKey, pair.value);
          _skipFlowSeparation(parentIndent);
          if (_cursor.consumeCodeUnit(CodeUnit.rightBrace)) break;
          if (!_cursor.consumeCodeUnit(CodeUnit.comma)) {
            _syntax(_expectedMappingSeparator, _cursor.pointSpan());
          }
          // Checking again after the comma accepts a trailing one.
          _skipFlowSeparation(parentIndent);
          if (_cursor.consumeCodeUnit(CodeUnit.rightBrace)) break;
        }
      }
      end = _cursor.mark;
    } finally {
      _leaveCollection();
    }
    return _finishMapping(
      entries.values,
      properties,
      start,
      end,
      nodeCount: nodeCount,
      aliasDepth: aliasDepth,
    );
  }

  /// Parses one explicit or implicit pair inside a flow mapping.
  ///
  /// [explicit] is `true` once a "?" indicator has been consumed,
  /// which lifts the simple-key length limit from the key.
  _NodePair _parseFlowPair(
    int parentIndent, {
    required bool explicit,
    required _MappingEntries entries,
  }) {
    final _BuiltNode key;
    if (_cursor.peek() == CodeUnit.colon) {
      key = _emptyNode(_markOffsetBy(1));
    } else if (_isFlowEntryEnd(_cursor.peek())) {
      if (!explicit) {
        _syntax('Expected a mapping key.', _cursor.pointSpan());
      }
      // "? ," and "? }" leave both halves empty, which still omits the ":".
      _rejectFlowEntryWithoutValue();
    } else {
      key = _parseFlowChild(parentIndent);
    }
    _skipFlowSeparation(parentIndent);
    if (_cursor.peek() != CodeUnit.colon) {
      // Only an entry that really ends here omitted its ":".
      // Anything else is malformed or unterminated,
      // which the enclosing loop describes better.
      if (_isFlowEntryEnd(_cursor.peek())) _rejectFlowEntryWithoutValue();
      _syntax(_expectedMappingSeparator, _cursor.pointSpan());
    }
    // Only an implicit key has to stay within the simple-key limit;
    // a "?" key can be arbitrarily long.
    // Length is measured from the key's start to the ":",
    // so that separation between them counts toward it.
    if (!explicit) {
      final end = _cursor.mark;
      _checkSimpleKeyLength(
        _countKeyCharacters(key.span.startOffset, end),
        end,
      );
    }
    final preparedKey = _prepareMappingKey(key, entries: entries);
    return (
      key: key,
      value: _parseFlowValue(parentIndent),
      preparedKey: preparedKey,
    );
  }

  /// Rejects a flow mapping entry written without its ":".
  Never _rejectFlowEntryWithoutValue() => _fail(
    YamlErrorCode.unsupportedFlowEntry,
    'Flow mapping entry has no ":".',
    _cursor.pointSpan(),
    hint: 'Write "key: value", or "key:" for a null value.',
  );

  /// Parses the value after a flow mapping colon.
  _BuiltNode _parseFlowValue(int parentIndent) {
    final indicator = _cursor.mark;
    _cursor.readCodeUnit();
    _skipFlowSeparation(parentIndent);
    if (_isFlowEntryEnd(_cursor.peek()) || _cursor.isDone) {
      return _emptyNode(indicator);
    }
    return _parseFlowChild(parentIndent);
  }

  /// Parses one child node inside a flow collection.
  _BuiltNode _parseFlowChild(int parentIndent) {
    _countParsedNode();
    final properties = _parseProperties();
    final propertiesStart = properties.start;
    if (propertiesStart != null) {
      // Properties standing alone before a delimiter
      // anchor or tag the empty scalar that the missing node resolves to.
      if (_isFlowEntryEnd(_cursor.peek()) || _cursor.peek() == CodeUnit.colon) {
        final at = _cursor.mark;
        return _buildScalar(
          '',
          ScalarStyle.plain,
          properties,
          propertiesStart,
          at,
        );
      }
      _skipFlowSeparation(parentIndent);
    }
    return _parseFlowNode(properties, parentIndent, keyContext: false);
  }

  /// Skips whitespace, comments, and valid line breaks in a flow collection.
  void _skipFlowSeparation(int parentIndent) {
    while (true) {
      final codeUnit = _skipTrailingComment();
      if (codeUnit != CodeUnit.lineFeed &&
          codeUnit != CodeUnit.carriageReturn) {
        return;
      }
      _cursor.readBreak();
      if (_isDocumentStartMarker || _isDocumentEndMarker) {
        _syntax(
          _invalidFlowSyntax,
          _cursor.pointSpan(),
        );
      }
      // Tabs beyond the leading spaces are separation rather than indentation,
      // so only the spaces count toward the required nesting.
      final indentationSpaces = _cursor.skipSpaces();
      while (_cursor.peek() == CodeUnit.tab) {
        _cursor.readCodeUnit();
      }
      // A flow collection can span lines,
      // but each continuation has to stay nested
      // inside the block context the collection started in.
      if (!_cursor.isDone &&
          !_cursor.isBreak &&
          _cursor.peek() != CodeUnit.numberSign &&
          indentationSpaces <= parentIndent) {
        _syntax(
          _invalidFlowSyntax,
          _cursor.pointSpan(),
        );
      }
    }
  }

  /// Whether the cursor is at a document-start marker.
  bool get _isDocumentStartMarker => _isDocumentMarker(CodeUnit.hyphenMinus);

  /// Whether the cursor is at a document-end marker.
  bool get _isDocumentEndMarker => _isDocumentMarker(CodeUnit.period);

  /// Whether the cursor is at a line of three [codeUnit] markers.
  bool _isDocumentMarker(int codeUnit) =>
      _cursor.column == 0 &&
      _cursor.peek() == codeUnit &&
      _cursor.peek(1) == codeUnit &&
      _cursor.peek(2) == codeUnit &&
      _isBlankBreakOrEnd(_cursor.peek(3));

  /// Consumes a three-character document boundary marker.
  void _consumeDocumentMarker() {
    _cursor.readCodeUnit();
    _cursor.readCodeUnit();
    _cursor.readCodeUnit();
  }

  /// Consumes a document-end marker and the remainder of its line.
  void _consumeDocumentEndMarker() {
    _consumeDocumentMarker();
    final afterMarker = _cursor.mark;
    _cursor.skipInlineWhitespace();
    if (_cursor.peek() == CodeUnit.numberSign) _skipComment();
    if (!_cursor.isDone && !_cursor.isBreak) {
      _syntax(
        'Expected break after marker.',
        _cursor.pointSpan(afterMarker),
      );
    }
    if (_cursor.isBreak) _cursor.readBreak();
  }

  /// Whether the cursor is at the "%" of a directive line.
  bool get _isDirectiveIndicator =>
      _cursor.column == 0 && _cursor.peek() == CodeUnit.percentSign;

  /// Whether the cursor is at a literal or folded block-scalar indicator.
  bool get _isBlockScalarIndicator =>
      _cursor.peek() == CodeUnit.verticalBar ||
      _cursor.peek() == CodeUnit.greaterThan;

  /// Whether the cursor is at a block-sequence entry indicator.
  bool get _isBlockSequenceIndicator =>
      _cursor.peek() == CodeUnit.hyphenMinus &&
      _isBlankBreakOrEnd(_cursor.peek(1));

  /// Whether the cursor is at an explicit block-mapping indicator.
  ///
  /// A value indicator counts as one: with no key before it, a ":" can only
  /// belong to a mapping whose key is empty.
  bool get _isBlockMappingIndicator =>
      _isMappingValueIndicator ||
      _cursor.peek() == CodeUnit.questionMark &&
          _isBlankBreakOrEnd(_cursor.peek(1));

  /// Whether the cursor is at a block-mapping value indicator.
  ///
  /// The leading colon of a line-opening `::` qualifies, as it does for
  /// [_isBlockMappingIndicator].
  bool get _isMappingValueIndicator =>
      _cursor.peek() == CodeUnit.colon &&
      (_isBlankBreakOrEnd(_cursor.peek(1)) ||
          _cursor.column == 0 && _cursor.peek(1) == CodeUnit.colon);

  /// Whether a ":" follows the scanned node, skipping the space before it.
  ///
  /// The cursor stops on the ":" when one follows,
  /// and rewinds to where the node ended when one doesn't,
  /// so a caller can treat the node as a mapping key or as a complete node.
  bool _skipToMappingValueIndicator() {
    final afterNode = _cursor.mark;
    _cursor.skipInlineWhitespace();
    if (_isMappingValueIndicator) return true;
    _cursor.restore(afterNode);
    return false;
  }

  /// Whether no content other than a comment remains on the current line.
  bool get _atLineEnd =>
      _cursor.isDone ||
      _cursor.isBreak ||
      _cursor.peek() == CodeUnit.numberSign;

  /// Advances across blank and comment-only lines to the next content.
  void _seekNextContentLine() {
    while (!_cursor.isDone) {
      if (_cursor.column != 0) return;
      _indentationTab = null;
      final spaces = _cursor.skipSpaces();
      _rejectByteOrderMark();
      if (_cursor.peek() == CodeUnit.tab) {
        // Remembered so that a later indentation error
        // can point at the tab that caused it
        // rather than at the content it precedes.
        _indentationTab = _cursor.mark;
        while (_isInlineWhitespace(_cursor.peek())) {
          _cursor.readCodeUnit();
        }
        // A tab never counts as indentation.
        // It's tolerated where it can't be read as any:
        // after a space, on a blank or comment line,
        // or before a flow collection,
        // which is delimited rather than indented.
        if (!_cursor.isDone &&
            !_cursor.isBreak &&
            _cursor.peek() != CodeUnit.numberSign &&
            spaces == 0 &&
            _cursor.peek() != CodeUnit.leftBracket &&
            _cursor.peek() != CodeUnit.leftBrace) {
          _syntax(
            _invalidIndentation,
            _cursor.pointSpan(),
          );
        }
      }
      if (_cursor.peek() == CodeUnit.numberSign) _skipComment();
      if (!_cursor.isBreak) return;
      _cursor.readBreak();
    }
  }

  /// Skips inline whitespace and a trailing comment on the current line.
  ///
  /// Rejects a comment that runs into preceding content,
  /// and returns the code unit the cursor stops at.
  int? _skipTrailingComment() {
    var codeUnit = _cursor.peek();
    final hadWhitespace = _isInlineWhitespace(codeUnit);
    if (hadWhitespace) {
      _cursor.skipInlineWhitespace();
      codeUnit = _cursor.peek();
    }
    if (codeUnit == CodeUnit.numberSign) {
      // A comment that neither starts its line nor follows whitespace
      // would run into the preceding content.
      if (!hadWhitespace &&
          !_isInlineWhitespace(_cursor.peek(-1)) &&
          _cursor.column != 0) {
        _syntax('Separate comment with whitespace.', _cursor.pointSpan());
      }
      _skipComment();
      codeUnit = _cursor.peek();
    }
    return codeUnit;
  }

  /// Validates and consumes the remainder of the current content line.
  void _finishLine() {
    final codeUnit = _skipTrailingComment();
    if (!_isBreakOrEnd(codeUnit)) {
      _syntax('Content follows node.', _cursor.pointSpan());
    }
    if (codeUnit != null) _cursor.readBreak();
  }

  /// Consumes a comment without consuming its terminating line break.
  void _skipComment() {
    while (true) {
      final codeUnit = _cursor.peek();
      if (_isBreakOrEnd(codeUnit)) return;
      if (codeUnit == CodeUnit.byteOrderMark) _rejectByteOrderMark();
      _cursor.readCodePoint();
    }
  }

  /// Destructively looks ahead from [afterText] for the best position
  /// to report a key beginning at [keyStart] that never reached its ":".
  SourceSpan _expectedColonSpan(
    ParserMark keyStart,
    ParserMark afterText,
  ) {
    _cursor.restore(afterText);
    while (!_cursor.isDone) {
      _cursor.skipInlineWhitespace();
      if (_cursor.peek() == CodeUnit.numberSign) _skipComment();
      if (!_cursor.isBreak) return _cursor.pointSpan();
      _cursor.readBreak();
      if (_cursor.isDone) return _cursor.pointSpan();

      _cursor.skipInlineWhitespace();
      if (_cursor.column <= keyStart.column ||
          _isDocumentStartMarker ||
          _isDocumentEndMarker) {
        return _cursor.pointSpan();
      }
      while (!_cursor.isDone && !_cursor.isBreak) {
        if (_cursor.peek() == CodeUnit.colon &&
            _isPlainIndicatorBoundary(_cursor.peek(1), flow: false)) {
          return _cursor.pointSpan();
        }
        _cursor.readCodePoint();
      }
    }
    return _cursor.pointSpan();
  }

  /// Destructively finds the start of the next line's content.
  SourceSpan _nextContentPointSpan() {
    while (!_cursor.isDone && !_cursor.isBreak) {
      _cursor.readCodePoint();
    }
    if (_cursor.isBreak) _cursor.readBreak();
    _cursor.skipInlineWhitespace();
    return _cursor.pointSpan();
  }

  /// Destructively locates the most useful span for trailing block content.
  ///
  /// [root] is `null` only for an empty document, which has no style to weigh.
  SourceSpan _unexpectedBlockContentSpan(_BuiltNode? root) {
    final tab = _indentationTab;
    if (tab != null && tab.line == _cursor.line) return _cursor.pointSpan(tab);

    if (_isBlockSequenceIndicator ||
        _currentLineHasMappingColon() ||
        _rootUsesFlowStyle(root) ||
        _previousLineContainsComment()) {
      return _cursor.pointSpan();
    }
    if (_cursor.peek() == CodeUnit.ampersand ||
        _cursor.peek() == CodeUnit.exclamationMark) {
      return _nextContentPointSpan();
    }
    while (!_cursor.isDone &&
        !_isDocumentStartMarker &&
        !_isDocumentEndMarker) {
      _cursor.readCodePoint();
    }
    return _cursor.pointSpan();
  }

  /// Whether the remaining current line contains a mapping-value colon.
  bool _currentLineHasMappingColon() {
    var offset = _cursor.offset;
    while (offset < _cursor.source.length) {
      final codeUnit = _cursor.source.codeUnitAt(offset);
      if (codeUnit == CodeUnit.lineFeed ||
          codeUnit == CodeUnit.carriageReturn) {
        return false;
      }
      if (codeUnit == CodeUnit.colon) {
        final next = offset + 1 == _cursor.source.length
            ? null
            : _cursor.source.codeUnitAt(offset + 1);
        if (_isBlankBreakOrEnd(next)) return true;
      }
      offset += 1;
    }
    return false;
  }

  /// Whether [root] begins with a flow-collection indicator.
  bool _rootUsesFlowStyle(_BuiltNode? root) {
    if (root == null) return false;
    final start = root.span.startOffset;
    if (start >= _cursor.source.length) return false;
    final codeUnit = _cursor.source.codeUnitAt(start);
    return codeUnit == CodeUnit.leftBracket || codeUnit == CodeUnit.leftBrace;
  }

  /// Whether the preceding source line contains a comment indicator.
  bool _previousLineContainsComment() {
    final lineStart = _cursor.offset - _cursor.column;
    if (lineStart == 0) return false;
    var previousEnd = lineStart - 1;
    if (_cursor.source.codeUnitAt(previousEnd) == CodeUnit.lineFeed &&
        previousEnd > 0 &&
        _cursor.source.codeUnitAt(previousEnd - 1) == CodeUnit.carriageReturn) {
      previousEnd -= 1;
    }
    var previousStart = previousEnd;
    while (previousStart > 0) {
      final codeUnit = _cursor.source.codeUnitAt(previousStart - 1);
      if (codeUnit == CodeUnit.lineFeed ||
          codeUnit == CodeUnit.carriageReturn) {
        break;
      }
      previousStart -= 1;
    }
    for (var offset = previousStart; offset < previousEnd; offset += 1) {
      if (_cursor.source.codeUnitAt(offset) == CodeUnit.numberSign) return true;
    }
    return false;
  }

  /// Counts one parsed node, reporting overflow at [at] or the cursor.
  void _countParsedNode([ParserMark? at]) {
    _parsedNodes += 1;
    if (_parsedNodes > DecoderLimit.parsedNodesPerDocument) {
      _fail(
        YamlErrorCode.resourceLimit,
        'Document exceeds ${DecoderLimit.parsedNodesPerDocument} parsed nodes.',
        _cursor.pointSpan(at),
      );
    }
  }

  /// Reserves [count] nodes before materializing output collections.
  void _reserveConstructed(int count, SourceSpan span) {
    if (_discarding) return;
    // Compared against the remaining budget rather than a sum,
    // so that a large alias expansion
    // can't overflow past the limit it's being checked against.
    if (_constructedNodes > DecoderLimit.constructedNodesPerDocument - count) {
      _defer(
        DecoderException(
          YamlErrorCode.resourceLimit,
          'Alias output exceeds ${DecoderLimit.constructedNodesPerDocument} '
          'constructed nodes.',
          span,
        ),
      );
      return;
    }
    _constructedNodes += count;
  }

  /// Defers [error], keeping only the first construction or profile failure.
  void _defer(DecoderException error) {
    _deferredError ??= error;
  }

  /// Throws a [DecoderException] for the syntax error [message] at [span].
  Never _syntax(String message, SourceSpan span) =>
      _fail(YamlErrorCode.syntax, message, span);

  /// Throws a [DecoderException] for the directive error [message] at [span].
  Never _invalidDirective(String message, SourceSpan span) =>
      _fail(YamlErrorCode.invalidDirective, message, span);

  /// Throws a [DecoderException] with the supplied diagnostic context.
  Never _fail(
    YamlErrorCode code,
    String message,
    SourceSpan span, {
    SourceSpan? relatedSpan,
    String? relatedLabel,
    String? hint,
  }) {
    throw DecoderException(
      code,
      message,
      span,
      relatedSpan: relatedSpan,
      relatedLabel: relatedLabel,
      hint: hint,
    );
  }
}

/// Returns the greater of [first] and [second].
int _max(int first, int second) => first > second ? first : second;

/// Whether [codeUnit] is YAML inline whitespace.
bool _isInlineWhitespace(int? codeUnit) =>
    codeUnit == CodeUnit.space || codeUnit == CodeUnit.tab;

/// Whether [text] contains only block-scalar whitespace.
bool _isBlankBlockScalarText(String text) {
  for (var index = 0; index < text.length; index += 1) {
    if (!_isInlineWhitespace(text.codeUnitAt(index))) return false;
  }
  return true;
}

/// Whether [text] begins with a space or a tab.
bool _startsWithInlineWhitespace(String text) =>
    text.isNotEmpty && _isInlineWhitespace(text.codeUnitAt(0));

/// Whether [codeUnit] is a line break or the end of input.
///
/// Testing an already-read code unit keeps a scanning loop
/// from reading the same position again
/// through [ParserCursor.isDone] and [ParserCursor.isBreak].
bool _isBreakOrEnd(int? codeUnit) =>
    codeUnit == null ||
    codeUnit == CodeUnit.lineFeed ||
    codeUnit == CodeUnit.carriageReturn;

/// Whether [codeUnit] is whitespace, a line break, or the end of input.
///
/// Spelled out rather than composed from
/// [_isBreakOrEnd] and [_isInlineWhitespace],
/// because the scanner consults it for nearly every character it reads.
bool _isBlankBreakOrEnd(int? codeUnit) =>
    codeUnit == null ||
    codeUnit == CodeUnit.space ||
    codeUnit == CodeUnit.tab ||
    codeUnit == CodeUnit.lineFeed ||
    codeUnit == CodeUnit.carriageReturn;

/// Whether [codeUnit] is an ASCII letter, digit, or hyphen.
bool _isAlphaNumericHyphen(int? codeUnit) =>
    _isAlphaNumeric(codeUnit) || codeUnit == CodeUnit.hyphenMinus;

/// Whether [codeUnit] is an ASCII letter or digit.
bool _isAlphaNumeric(int? codeUnit) =>
    CodeUnit.isAsciiDigit(codeUnit) ||
    codeUnit != null &&
        (codeUnit >= CodeUnit.uppercaseA && codeUnit <= CodeUnit.uppercaseZ ||
            codeUnit >= CodeUnit.lowercaseA && codeUnit <= CodeUnit.lowercaseZ);

/// Whether [codeUnit] delimits a node in a flow collection.
bool _isFlowDelimiter(int? codeUnit) =>
    _isFlowEntryEnd(codeUnit) ||
    codeUnit == CodeUnit.leftBracket ||
    codeUnit == CodeUnit.leftBrace;

/// Whether [codeUnit] ends a flow entry: a ",", "]", or "}".
bool _isFlowEntryEnd(int? codeUnit) =>
    codeUnit == CodeUnit.comma ||
    codeUnit == CodeUnit.rightBracket ||
    codeUnit == CodeUnit.rightBrace;

/// Whether [codeUnit] can follow an indicator in a flow collection.
bool _isFlowIndicatorBoundary(int? codeUnit) =>
    _isBlankBreakOrEnd(codeUnit) || _isFlowEntryEnd(codeUnit);

/// Whether [codeUnit] makes a preceding `-`, `?`, or `:` an indicator.
///
/// Such a character both keeps a plain scalar from starting at the indicator,
/// and ends one that a `:` would otherwise continue.
bool _isPlainIndicatorBoundary(int? codeUnit, {required bool flow}) =>
    _isBlankBreakOrEnd(codeUnit) || flow && _isFlowDelimiter(codeUnit);

/// Whether [codeUnit] can occur in an anchor or alias name.
///
/// This is the specification's set, which the decoder scans
/// before narrowing the name with [_isSupportedAnchorName].
bool _isAnchorCharacter(int? codeUnit) =>
    codeUnit != null &&
    !_isBlankBreakOrEnd(codeUnit) &&
    codeUnit != CodeUnit.comma &&
    codeUnit != CodeUnit.leftBracket &&
    codeUnit != CodeUnit.rightBracket &&
    codeUnit != CodeUnit.leftBrace &&
    codeUnit != CodeUnit.rightBrace;

/// Whether [name] is within the anchor-name set this package accepts.
///
/// The specification allows every character [_isAnchorCharacter] admits,
/// which makes `&*x`, `&&x`, and `&x#y` legal names,
/// and reads `*x: 2` as an alias to an anchor named `x:`.
/// A name is pure presentation and never reaches a decoded value,
/// so narrowing it to an identifier costs no expressiveness
/// and leaves nothing that looks like another construct.
///
/// [name] must not be empty.
bool _isSupportedAnchorName(String name) {
  assert(name.isNotEmpty, 'Expected a scanned anchor name.');
  final first = name.codeUnitAt(0);
  if (!_isAlphaNumeric(first) && first != CodeUnit.underscore) return false;
  for (var index = 1; index < name.length; index += 1) {
    final codeUnit = name.codeUnitAt(index);
    if (!_isAlphaNumericHyphen(codeUnit) &&
        codeUnit != CodeUnit.underscore &&
        codeUnit != CodeUnit.period) {
      return false;
    }
  }
  return true;
}

/// Whether [codeUnit] can occur in an encoded tag suffix.
bool _isTagCharacter(int? codeUnit) =>
    codeUnit != null &&
    !_isBlankBreakOrEnd(codeUnit) &&
    codeUnit != CodeUnit.comma &&
    codeUnit != CodeUnit.leftBracket &&
    codeUnit != CodeUnit.rightBracket;

/// Whether [handle] has the syntax of a named tag handle.
bool _isValidNamedTagHandle(String handle) {
  if (handle.length < 3 ||
      handle.codeUnitAt(0) != CodeUnit.exclamationMark ||
      handle.codeUnitAt(handle.length - 1) != CodeUnit.exclamationMark) {
    return false;
  }
  for (var index = 1; index < handle.length - 1; index += 1) {
    if (!_isAlphaNumericHyphen(handle.codeUnitAt(index))) return false;
  }
  return true;
}
