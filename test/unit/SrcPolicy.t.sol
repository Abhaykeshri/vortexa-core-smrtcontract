// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PriceGuard} from "../../src/PriceGuard.sol";
import {IStateViewLike} from "../../src/interfaces/external/IStateViewLike.sol";

// @dev Enforces, on every file under `src/`, the rules the developer guide assigns to CI plus the project's
//    NatSpec rule, so a violation fails `forge test` even without a hosted CI pipeline:
//    - first line is an SPDX identifier of MIT or UNLICENSED;
//    - `pragma solidity 0.8.26;` exactly (no caret, no range);
//    - no Uniswap source or test aliases (`uni-test`, `@uniswap/`), `selfdestruct`, `tx.origin`, `delegatecall`,
//    revert strings or `require`;
//    - every contract, library, interface, function, constructor, modifier, error, event, struct, enum,
//    user-defined type, constant, immutable and mapping carries NatSpec, with `@title/@notice/@dev` on
//    contract-like declarations, `@notice` and `@dev` on functions, and an `@param` for every named
//    parameter plus an `@return` when the function returns something (`@inheritdoc` is accepted instead).
//    Scanner behaviour is itself verified against deliberately bad snippets.
contract SrcPolicyTest is Test {
    string[] internal failures;

    // ------------------------------------------------------------------------------------------------------------
    // The real check
    // ------------------------------------------------------------------------------------------------------------

    function test_every_src_file_satisfies_the_project_policy() public {
        VmSafe.DirEntry[] memory entries = vm.readDir("src", 10);
        uint256 filesChecked;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || !_endsWith(entries[i].path, ".sol")) continue;
            filesChecked++;
            _scan(entries[i].path, vm.readFile(entries[i].path));
        }
        assertGt(filesChecked, 10, "expected to scan every src file");

        for (uint256 i; i < failures.length; ++i) {
            emit log_string(failures[i]);
        }
        assertEq(failures.length, 0, "src policy violations (listed above)");
    }

    function test_production_contracts_fit_the_contract_size_limit_with_headroom() public {
        PriceGuard guard = new PriceGuard(IStateViewLike(address(0x1)), address(0), address(0x2), address(this));
        assertLt(address(guard).code.length, 24_576 - 2_000, "PriceGuard approaches the EIP-170 limit");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Negative controls: the scanner must reject bad code and accept good code
    // ------------------------------------------------------------------------------------------------------------

    string internal constant HEADER = "// SPDX-License-Identifier: MIT\npragma solidity 0.8.26;\n";

    function test_scanner_accepts_a_fully_documented_contract() public {
        assertEq(_violations(string.concat(HEADER, _goodContract())), 0);
    }

    function test_scanner_rejects_a_wrong_spdx_identifier_or_pragma() public {
        string memory body = _goodContract();
        assertGt(_violations(string.concat("// SPDX-License-Identifier: GPL-3.0\npragma solidity 0.8.26;\n", body)), 0);
        assertGt(_violations(string.concat("// SPDX-License-Identifier: MIT\npragma solidity ^0.8.26;\n", body)), 0);
        assertGt(_violations(string.concat("// SPDX-License-Identifier: MIT\npragma solidity >=0.8.0;\n", body)), 0);
    }

    function test_scanner_rejects_forbidden_constructs() public {
        string memory withExtra;
        withExtra = string.concat(HEADER, 'import {X} from "uni-test/v4-core/X.sol";\n', _goodContract());
        assertGt(_violations(withExtra), 0);
        withExtra = string.concat(HEADER, 'import {X} from "@uniswap/v4-core/X.sol";\n', _goodContract());
        assertGt(_violations(withExtra), 0);
        withExtra = string.concat(HEADER, _contractWithBody('        revert("nope");\n'));
        assertGt(_violations(withExtra), 0);
        withExtra = string.concat(HEADER, _contractWithBody("        require(true, \"x\");\n"));
        assertGt(_violations(withExtra), 0);
        withExtra = string.concat(HEADER, _contractWithBody("        selfdestruct(payable(msg.sender));\n"));
        assertGt(_violations(withExtra), 0);
        withExtra = string.concat(HEADER, _contractWithBody("        address a = tx.origin; a;\n"));
        assertGt(_violations(withExtra), 0);
        withExtra = string.concat(HEADER, _contractWithBody('        (bool ok,) = msg.sender.delegatecall(""); ok;\n'));
        assertGt(_violations(withExtra), 0);
    }

    function test_scanner_ignores_forbidden_words_inside_comments() public {
        string memory body = string.concat(
            "/// @title T\n/// @notice N\n/// @dev Never use selfdestruct, tx.origin or delegatecall; see @uniswap/ docs.\n",
            "contract T {\n    // require( is discussed here\n}\n"
        );
        assertEq(_violations(string.concat(HEADER, body)), 0);
    }

    function test_scanner_rejects_undocumented_declarations() public {
        assertGt(_violations(string.concat(HEADER, "contract T {}\n")), 0, "contract without NatSpec");
        assertGt(
            _violations(string.concat(HEADER, "/// @title T\n/// @notice N\ncontract T {}\n")),
            0,
            "contract without @dev"
        );
        assertGt(
            _violations(string.concat(HEADER, _wrap("    function f() external {}\n"))), 0, "function without NatSpec"
        );
        assertGt(_violations(string.concat(HEADER, _wrap("    error E();\n"))), 0, "error without NatSpec");
        assertGt(_violations(string.concat(HEADER, _wrap("    uint256 internal constant C = 1;\n"))), 0, "constant");
        assertGt(
            _violations(string.concat(HEADER, _wrap("    mapping(uint256 => uint256) private m;\n"))), 0, "mapping"
        );
        assertGt(_violations(string.concat(HEADER, _wrap("    struct S { uint256 a; }\n"))), 0, "struct");
    }

    function test_scanner_rejects_incomplete_function_documentation() public {
        // missing @dev
        string memory noDev =
            _wrap("    /// @notice Does f.\n    /// @param a First.\n    function f(uint256 a) external {}\n");
        assertGt(_violations(string.concat(HEADER, noDev)), 0, "missing @dev");
        // missing @param
        string memory noParam = _wrap(
            "    /// @notice Does f.\n    /// @dev Details.\n    /// @param a First.\n    function f(uint256 a, uint256 b) external {}\n"
        );
        assertGt(_violations(string.concat(HEADER, noParam)), 0, "missing @param b");
        // missing @return
        string memory noReturn = _wrap(
            "    /// @notice Does f.\n    /// @dev Details.\n    function f() external pure returns (uint256 value) { return 1; }\n"
        );
        assertGt(_violations(string.concat(HEADER, noReturn)), 0, "missing @return");
    }

    function test_scanner_handles_multiline_signatures_and_inheritdoc() public {
        string memory multiline = _wrap(
            "    /// @notice Does f.\n    /// @dev Details.\n    /// @param first First.\n    /// @param second Second.\n    /// @return value Result.\n"
            "    function f(\n        uint256 first,\n        uint256 second\n    ) external pure returns (uint256 value) {\n        return first + second;\n    }\n"
        );
        assertEq(_violations(string.concat(HEADER, multiline)), 0, "documented multiline function is accepted");

        string memory multilineMissing = _wrap(
            "    /// @notice Does f.\n    /// @dev Details.\n    /// @param first First.\n    /// @return value Result.\n"
            "    function f(\n        uint256 first,\n        uint256 second\n    ) external pure returns (uint256 value) {\n        return first + second;\n    }\n"
        );
        assertGt(_violations(string.concat(HEADER, multilineMissing)), 0, "undocumented second parameter");

        string memory inherited = _wrap("    /// @inheritdoc IThing\n    function f(uint256 a) external {}\n");
        assertEq(_violations(string.concat(HEADER, inherited)), 0, "@inheritdoc is accepted");
    }

    function test_scanner_accepts_block_style_natspec() public {
        string memory block_ = string.concat(
            "/**\n * @title T\n * @notice N\n * @dev D\n */\ncontract T {\n",
            "    /**\n     * @notice Does f.\n     * @dev Details.\n     * @param a First.\n     * @return b Result.\n     */\n",
            "    function f(uint256 a) external pure returns (uint256 b) {\n        return a;\n    }\n",
            "    /** @dev A constant. */\n    uint256 internal constant C = 1;\n}\n"
        );
        assertEq(_violations(string.concat(HEADER, block_)), 0);
    }

    function test_scanner_rejects_incomplete_block_style_natspec() public {
        string memory head = "/**\n * @title T\n * @notice N\n * @dev D\n */\ncontract T {\n";
        // missing @param b
        string memory noParam = string.concat(
            head,
            "    /**\n     * @notice Does f.\n     * @dev Details.\n     * @param a First.\n     */\n",
            "    function f(uint256 a, uint256 b) external {}\n}\n"
        );
        assertGt(_violations(string.concat(HEADER, noParam)), 0, "missing @param in a block");
        // a plain comment block is not NatSpec
        string memory plain = string.concat(
            head, "    /*\n     * @notice Does f.\n     * @dev Details.\n     */\n    function f() external {}\n}\n"
        );
        assertGt(_violations(string.concat(HEADER, plain)), 0, "plain /* */ is not NatSpec");
        // a blank line detaches the comment from the declaration
        string memory detached = string.concat(
            head, "    /**\n     * @notice Does f.\n     * @dev Details.\n     */\n\n    function f() external {}\n}\n"
        );
        assertGt(_violations(string.concat(HEADER, detached)), 0, "detached comment");
        // forbidden words inside a block comment are ignored
        string memory words = string.concat(
            "/**\n * @title T\n * @notice N\n * @dev Never use selfdestruct or tx.origin.\n */\ncontract T {}\n"
        );
        assertEq(_violations(string.concat(HEADER, words)), 0, "comment text is not code");
    }

    function test_scanner_allows_lint_comments_between_block_natspec_and_declaration() public {
        string memory body = string.concat(
            "/**\n * @title T\n * @notice N\n * @dev D\n */\ncontract T {\n",
            "    /**\n     * @notice Does f.\n     * @dev Details.\n     */\n",
            "    // forge-lint: disable-next-line(unused-return)\n    function f() external {}\n}\n"
        );
        assertEq(_violations(string.concat(HEADER, body)), 0);
    }

    function test_scanner_allows_plain_comments_between_natspec_and_declaration() public {
        string memory body = _wrap(
            "    /// @notice Does f.\n    /// @dev Details.\n    // forge-lint: disable-next-line(unused-return)\n    function f() external {}\n"
        );
        assertEq(_violations(string.concat(HEADER, body)), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Scanner
    // ------------------------------------------------------------------------------------------------------------

    /**
     * Project rule (2026-10-12): NatSpec in `src/` is written as block comments (slash, two stars), never as
     * triple-slash lines. The scanner above accepts both styles, so this check enforces the block style on its own.
     */
    function test_src_uses_block_natspec_only() public {
        VmSafe.DirEntry[] memory entries = vm.readDir("src", 10);
        uint256 offenders;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || !_endsWith(entries[i].path, ".sol")) continue;
            string[] memory lines = vm.split(vm.readFile(entries[i].path), "\n");
            for (uint256 j; j < lines.length; ++j) {
                if (_startsWith(vm.trim(lines[j]), "///")) {
                    emit log_string(string.concat(entries[i].path, ":", vm.toString(j + 1), ": `///` NatSpec"));
                    offenders++;
                }
            }
        }
        assertEq(offenders, 0, "use /** */ NatSpec blocks in src/, never ///");
    }

    function _violations(string memory content) internal returns (uint256 count) {
        delete failures;
        _scan("snippet.sol", content);
        count = failures.length;
        delete failures;
    }

    function _scan(string memory path, string memory content) internal {
        if (
            !_startsWith(content, "// SPDX-License-Identifier: MIT\n")
                && !_startsWith(content, "// SPDX-License-Identifier: UNLICENSED\n")
        ) _fail(path, 1, "first line must be an SPDX identifier of MIT or UNLICENSED");
        if (!vm.contains(content, "\npragma solidity 0.8.26;\n")) {
            _fail(path, 0, "pragma must be exactly `pragma solidity 0.8.26;`");
        }

        string[] memory lines = vm.split(content, "\n");
        for (uint256 i; i < lines.length; ++i) {
            string memory line = vm.trim(lines[i]);
            if (bytes(line).length == 0 || _startsWith(line, "//") || _startsWith(line, "*") || _startsWith(line, "/*"))
            {
                continue;
            }

            _checkForbidden(path, lines, i, line);
            (bool isDeclaration, uint8 kind) = _declarationKind(line);
            if (isDeclaration) _checkNatSpec(path, lines, i, kind);
        }
    }

    function _checkForbidden(string memory path, string[] memory lines, uint256 lineIndex, string memory line)
        internal
    {
        string[8] memory banned = [
            "uni-test",
            "@uniswap/",
            "selfdestruct",
            "tx.origin",
            "delegatecall",
            "revert(\"",
            "require(",
            "pragma experimental"
        ];
        for (uint256 i; i < banned.length; ++i) {
            if (_eq(banned[i], "delegatecall") && lineIndex > 0) {
                string memory prev = vm.trim(lines[lineIndex - 1]);
                if (_startsWith(prev, "// forge-policy: allow-controlled-delegatecall")) continue;
            }
            if (vm.contains(line, banned[i])) {
                _fail(path, lineIndex + 1, string.concat("forbidden construct: ", banned[i]));
            }
        }
    }

    // declaration kinds: 1 contract-like, 2 function-like, 3 error/event/struct/enum/type, 4 state variable
    function _declarationKind(string memory line) internal pure returns (bool, uint8) {
        if (
            _startsWith(line, "contract ") || _startsWith(line, "abstract contract ") || _startsWith(line, "library ")
                || _startsWith(line, "interface ")
        ) return (true, 1);
        if (
            _startsWith(line, "function ") || _startsWith(line, "constructor") || _startsWith(line, "modifier ")
                || _startsWith(line, "receive()") || _startsWith(line, "fallback()")
        ) return (true, 2);
        if (
            _startsWith(line, "error ") || _startsWith(line, "event ") || _startsWith(line, "struct ")
                || _startsWith(line, "enum ") || _startsWith(line, "type ")
        ) return (true, 3);
        if (_startsWith(line, "mapping(") || _contains(line, " constant ") || _contains(line, " immutable ")) {
            if (!_startsWith(line, "return ")) return (true, 4);
        }
        return (false, 0);
    }

    function _checkNatSpec(string memory path, string[] memory lines, uint256 declLine, uint8 kind) internal {
        (bool found, string memory natspec) = _natspecAbove(lines, declLine);
        string memory decl = vm.trim(lines[declLine]);
        if (!found) {
            _fail(path, declLine + 1, string.concat("missing NatSpec: ", decl));
            return;
        }
        if (kind == 1) {
            if (!_contains(natspec, "@title") || !_contains(natspec, "@notice") || !_contains(natspec, "@dev")) {
                _fail(path, declLine + 1, string.concat("contract-like needs @title, @notice and @dev: ", decl));
            }
        } else if (kind == 2) {
            _checkFunctionNatSpec(path, lines, declLine, natspec);
        } else if (kind == 3) {
            if (!_contains(natspec, "@notice")) _fail(path, declLine + 1, string.concat("needs @notice: ", decl));
        } else if (!_contains(natspec, "@notice") && !_contains(natspec, "@dev")) {
            _fail(path, declLine + 1, string.concat("state variable needs @notice or @dev: ", decl));
        }
    }

    function _checkFunctionNatSpec(string memory path, string[] memory lines, uint256 declLine, string memory natspec)
        internal
    {
        if (_contains(natspec, "@inheritdoc")) return;
        string memory decl = vm.trim(lines[declLine]);
        if (!_contains(natspec, "@notice")) _fail(path, declLine + 1, string.concat("function needs @notice: ", decl));
        if (!_contains(natspec, "@dev")) _fail(path, declLine + 1, string.concat("function needs @dev: ", decl));

        string memory signature = _signature(lines, declLine);
        string[] memory names = _parameterNames(signature);
        for (uint256 i; i < names.length; ++i) {
            if (!_contains(natspec, string.concat("@param ", names[i], " "))) {
                _fail(path, declLine + 1, string.concat("missing @param ", names[i], " on: ", decl));
            }
        }
        if (_contains(signature, " returns (") && !_contains(natspec, "@return")) {
            _fail(path, declLine + 1, string.concat("missing @return on: ", decl));
        }
    }

    /**
     * @dev Finds the NatSpec directly above a declaration, in either style: a `/** ... *\/` block (the project
     *      style) or a contiguous run of `///` lines. Plain `//` comments (such as lint directives) between the
     *      NatSpec and the declaration are skipped; blank lines or code stop the search. A plain `/* ... *\/`
     *      comment is not NatSpec.
     */
    function _natspecAbove(string[] memory lines, uint256 declLine) internal pure returns (bool, string memory) {
        uint256 k = declLine;
        while (k > 0) {
            k--;
            string memory prev = vm.trim(lines[k]);
            if (_startsWith(prev, "///")) return _lineStyleNatSpec(lines, k);
            if (_endsWith(prev, "*/")) return _blockStyleNatSpec(lines, k);
            if (_startsWith(prev, "//")) continue;
            return (false, "");
        }
        return (false, "");
    }

    function _lineStyleNatSpec(string[] memory lines, uint256 last) private pure returns (bool, string memory) {
        string memory block_ = "";
        uint256 k = last;
        while (true) {
            string memory current = vm.trim(lines[k]);
            if (!_startsWith(current, "///")) break;
            block_ = string.concat(current, "\n", block_);
            if (k == 0) break;
            k--;
        }
        return (true, block_);
    }

    /**
     * @dev `close` is the line that ends with the closing marker; walks up to the line that opens the block.
     */
    function _blockStyleNatSpec(string[] memory lines, uint256 close) private pure returns (bool, string memory) {
        string memory block_ = "";
        uint256 k = close;
        while (true) {
            string memory current = vm.trim(lines[k]);
            block_ = string.concat(current, "\n", block_);
            if (_startsWith(current, "/*")) return (_startsWith(current, "/**"), block_);
            if (k == 0) return (false, "");
            k--;
        }
        return (false, "");
    }

    function _signature(string[] memory lines, uint256 declLine) internal pure returns (string memory sig) {
        for (uint256 i = declLine; i < lines.length; ++i) {
            string memory line = vm.trim(lines[i]);
            sig = string.concat(sig, " ", line);
            if (_contains(line, "{") || _endsWith(line, ";")) break;
        }
    }

    function _parameterNames(string memory signature) internal pure returns (string[] memory names) {
        bytes memory s = bytes(signature);
        uint256 open = type(uint256).max;
        uint256 depth;
        uint256 close;
        for (uint256 i; i < s.length; ++i) {
            if (s[i] == "(") {
                if (open == type(uint256).max) open = i;
                depth++;
            } else if (s[i] == ")") {
                depth--;
                if (depth == 0 && open != type(uint256).max) {
                    close = i;
                    break;
                }
            }
        }
        if (open == type(uint256).max || close <= open + 1) return new string[](0);

        bytes memory inner = new bytes(close - open - 1);
        for (uint256 i; i < inner.length; ++i) {
            inner[i] = s[open + 1 + i];
        }
        string[] memory parts = vm.split(string(inner), ",");
        string[] memory tmp = new string[](parts.length);
        uint256 count;
        for (uint256 i; i < parts.length; ++i) {
            string[] memory tokens = vm.split(vm.trim(parts[i]), " ");
            string memory last = "";
            uint256 tokenCount;
            for (uint256 t; t < tokens.length; ++t) {
                if (bytes(tokens[t]).length == 0) continue;
                last = tokens[t];
                tokenCount++;
            }
            if (tokenCount < 2) continue; // unnamed parameter
            if (_eq(last, "memory") || _eq(last, "calldata") || _eq(last, "storage") || _eq(last, "payable")) continue;
            tmp[count++] = last;
        }
        names = new string[](count);
        for (uint256 i; i < count; ++i) {
            names[i] = tmp[i];
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // String helpers and snippets
    // ------------------------------------------------------------------------------------------------------------

    function _fail(string memory path, uint256 lineNo, string memory message) internal {
        failures.push(string.concat(path, ":", vm.toString(lineNo), " ", message));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        return vm.contains(haystack, needle);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }

    function _wrap(string memory members) internal pure returns (string memory) {
        return string.concat("/// @title T\n/// @notice N\n/// @dev D\ncontract T {\n", members, "}\n");
    }

    function _goodContract() internal pure returns (string memory) {
        return _wrap(
            "    /// @notice Does f.\n    /// @dev Details.\n    /// @param a First.\n    /// @return b Result.\n"
            "    function f(uint256 a) external pure returns (uint256 b) {\n        return a;\n    }\n"
        );
    }

    function _contractWithBody(string memory statement) internal pure returns (string memory) {
        return _wrap(
            string.concat(
                "    /// @notice Does f.\n    /// @dev Details.\n    function f() external {\n", statement, "    }\n"
            )
        );
    }
}
