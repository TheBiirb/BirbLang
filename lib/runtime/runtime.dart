import 'dart:io';

import 'package:Birb/core_types/core_types.dart';
import 'package:Birb/utils/ast/ast_node.dart';
import 'package:Birb/utils/ast/ast_types.dart';
import 'package:Birb/utils/exceptions.dart';
import 'package:Birb/utils/scope.dart';
import 'package:Birb/parser/data_type.dart';
import 'package:Birb/runtime/standards.dart';
import 'package:Birb/lexer/token.dart';

class Runtime {
  Scope scope;
  List listMethods;
  List mapMethods;
  String stdoutBuffer;
  String path;

  List<Map> stack = [];
}

Runtime initRuntime(String path) {
  var runtime = Runtime()
    ..path = path
    ..scope = initScope(true)
    ..listMethods = []
    ..mapMethods = [];

  INITIALIZED_NOOP = NoopNode();

  initStandards(runtime, path);

  var LIST_ADD_FUNCTION_DEFINITION = FuncDefNode();
  LIST_ADD_FUNCTION_DEFINITION.funcName = 'add';
  LIST_ADD_FUNCTION_DEFINITION.funcPointer = listAddFuncPointer;
  runtime.listMethods.add(LIST_ADD_FUNCTION_DEFINITION);

  var LIST_REMOVE_FUNCTION_DEFINITION = FuncDefNode();
  LIST_REMOVE_FUNCTION_DEFINITION.funcName = 'remove';
  LIST_REMOVE_FUNCTION_DEFINITION.funcPointer = listRemoveFuncPointer;
  runtime.listMethods.add(LIST_REMOVE_FUNCTION_DEFINITION);

  var MAP_ADD_FUNCTION_DEFINITION = FuncDefNode();
  MAP_ADD_FUNCTION_DEFINITION.funcName = 'add';
  MAP_ADD_FUNCTION_DEFINITION.funcPointer = mapAddFuncPointer;
  runtime.mapMethods.add(MAP_ADD_FUNCTION_DEFINITION);

  var MAP_REMOVE_FUNCTION_DEFINITION = FuncDefNode();
  MAP_REMOVE_FUNCTION_DEFINITION.funcName = 'remove';
  MAP_REMOVE_FUNCTION_DEFINITION.funcPointer = mapAddFuncPointer;
  runtime.mapMethods.add(MAP_REMOVE_FUNCTION_DEFINITION);

  return runtime;
}

Scope getScope(Runtime runtime, ASTNode node) {
  return node.scope ?? runtime.scope;
}

void multipleVariableDefinitionsError(int lineNum, String variableName) {
  throw MultipleVariableDefinitionsException(
      '[Line $lineNum] variable `$variableName` is already defined');
}

ASTNode listAddFuncPointer(Runtime runtime, ASTNode self, List args) {
  self.listElements.addAll(args);

  return self;
}

ASTNode listRemoveFuncPointer(Runtime runtime, ASTNode self, List args) {
  runtimeExpectArgs(args, [ASTType.AST_INT]);

  ASTNode ast_int = args[0];

  if (ast_int.intVal > self.listElements.length) {
    throw RangeException('Index out of range');
  }

  self.listElements.remove(self.listElements[ast_int.intVal]);

  return self;
}

ASTNode mapAddFuncPointer(Runtime runtime, ASTNode self, List args) {
  runtimeExpectArgs(args, [ASTType.AST_STRING, ASTType.AST_ANY]);

  self.map[args[0]] = args[1];
  return self;
}

ASTNode mapRemoveFuncPointer(Runtime runtime, ASTNode self, List args) {
  runtimeExpectArgs(args, [ASTType.AST_STRING]);

  ASTNode astString = args[0];

  if (!self.map.containsKey(astString.stringValue))
    throw MapEntryNotFoundException(
        'Map does not contain `${astString.stringValue}`');

  self.map.remove(astString.stringValue);
  return self;
}

void collectAndSweepGarbage(Runtime runtime, List oldDefList, Scope scope) {
  if (scope == runtime.scope) return;

  var garbage = [];

  for (ASTNode newDef in scope.variableDefinitions)
    if (!oldDefList.contains(newDef)) garbage.add(newDef);

  for (var garb in garbage) scope.variableDefinitions.remove(garb);
}

Future<ASTNode> runtimeFuncCall(
    Runtime runtime, ASTNode fCall, ASTNode fDef) async {
  if (fCall.funcCallArgs.length != fDef.funcDefArgs.length)
    throw InvalidArgumentsException(
        'Error: [Line ${fCall.lineNum}] ${fDef.funcName} Expected ${fDef.funcDefArgs.length} arguments but found ${fCall.funcCallArgs.length} arguments\n');

  var funcDefBodyScope = fDef.funcDefBody.scope;

  funcDefBodyScope.variableDefinitions.clear();

  for (int x = 0; x < fCall.funcCallArgs.length; x++) {
    ASTNode astArg = fCall.funcCallArgs[x];

    if (x > fDef.funcDefArgs.length - 1)
      throw InvalidArgumentsException(
          'Error: [Line ${astArg.lineNum}] Too many arguments\n');

    ASTNode astFDefArg = fDef.funcDefArgs[x];
    var argName = astFDefArg.variableName;

    var newVariableDef = VarDefNode();
    newVariableDef.variableType = astFDefArg.variableType;

    if (astArg.type == ASTType.AST_VARIABLE) {
      var vdef = await getVarDefByName(
          runtime, getScope(runtime, astArg), astArg.variableName);

      if (vdef != null) newVariableDef.variableValue = vdef.variableValue;
    }

    newVariableDef.variableValue ??= await visit(runtime, astArg);
    newVariableDef.variableName = argName;

    funcDefBodyScope.variableDefinitions.add(newVariableDef);
  }

  return await visit(runtime, fDef.funcDefBody);
}

ASTNode registerGlobalFunction(
    Runtime runtime, String fName, AstFuncPointer funcPointer) {
  var fDef = FuncDefNode();
  fDef.funcName = fName;
  fDef.funcPointer = funcPointer;
  runtime.scope.functionDefinitions.add(fDef);
  return fDef;
}

ASTNode registerGlobalFutureFunction(
    Runtime runtime, String fName, AstFutureFuncPointer funcPointer) {
  var fDef = FuncDefNode()
    ..funcName = fName
    ..futureFuncPointer = funcPointer;
  runtime.scope.functionDefinitions.add(fDef);
  return fDef;
}

ASTNode registerGlobalVariable(
    Runtime runtime, String varName, ASTNode varVal) {
  ASTNode varDef = VarDefNode()
    ..variableName = varName
    ..variableType = StringNode()
    ..variableValue = varVal;
  runtime.scope.variableDefinitions.add(varDef);
  return varDef;
}

Future<ASTNode> visit(Runtime runtime, ASTNode node) async {
  if (node == null) return null;

  switch (node.type) {
    case ASTType.AST_CLASS:
      runtime.stack.add({'line': node.lineNum, 'function': node.className});

      if (node.superClass != null) {
        ClassNode superClass = await visit(runtime, node.superClass);
        List nullVars = node.classChildren
            .where((child) =>
                child is VarDefNode &&
                child.variableValue == null &&
                child.isSuperseding)
            .toList();

        nullVars.forEach((child) {
          ASTNode superVariable = superClass.classChildren.firstWhere(
              (superChild) =>
                  (superChild as ASTNode).variableName ==
                  (child as ASTNode).variableName);
          (child as ASTNode).variableValue = superVariable.variableValue;
        });
      }
      return node;
    case ASTType.AST_ENUM:
      return node;
    case ASTType.AST_VARIABLE:
      return await visitVariable(runtime, node);
    case ASTType.AST_VARIABLE_DEFINITION:
      return await visitVarDef(runtime, node);
    case ASTType.AST_VARIABLE_ASSIGNMENT:
      return await visitVarAssignment(runtime, node);
    case ASTType.AST_VARIABLE_MODIFIER:
      return await visitVarMod(runtime, node);
    case ASTType.AST_FUNC_DEFINITION:
      return await visitFuncDef(runtime, node);
    case ASTType.AST_FUNC_CALL:
      return await visitFuncCall(runtime, node);
    case ASTType.AST_NULL:
      return node;
    case ASTType.AST_STRING:
      return node;
    case ASTType.AST_STRING_BUFFER:
      return node;
    case ASTType.AST_DOUBLE:
      return node;
    case ASTType.AST_LIST:
      node.funcDefinitions = runtime.listMethods;
      return node;
    case ASTType.AST_MAP:
      node.funcDefinitions = runtime.mapMethods;
      return node;
    case ASTType.AST_BOOL:
      return node;
    case ASTType.AST_INT:
      return node;
    case ASTType.AST_COMPOUND:
      return await visitCompound(runtime, node);
    case ASTType.AST_TYPE:
      return node;
    case ASTType.AST_BINARYOP:
      return await visitBinaryOp(runtime, node);
    case ASTType.AST_UNARYOP:
      return await visitUnaryOp(runtime, node);
    case ASTType.AST_NOOP:
      return node;
    case ASTType.AST_BREAK:
      return node;
    case ASTType.AST_RETURN:
      return node;
    case ASTType.AST_THROW:
      ClassNode throwArg = await visit(runtime, node.throwValue);

      String classToString = '';

      throwArg.classChildren
          .where((child) => (child as ASTNode) is VarDefNode)
          .forEach((varDef) {
        classToString +=
            '\t${(varDef as VarDefNode).variableName}: ${astToString((varDef as VarDefNode).variableValue)}\n';
      });

      stderr.write('${throwArg.className}:\n$classToString');
      exit(1);

      return INITIALIZED_NOOP;
    case ASTType.AST_CONTINUE:
      return node;
    case ASTType.AST_TERNARY:
      return await visitTernary(runtime, node);
    case ASTType.AST_IF:
      return await visitIf(runtime, node);
    case ASTType.AST_SWITCH:
      return await visitSwitch(runtime, node);
    case ASTType.AST_WHILE:
      return await visitWhile(runtime, node);
    case ASTType.AST_FOR:
      return await visitFor(runtime, node);
    case ASTType.AST_ATTRIBUTE_ACCESS:
      return await visitAttAccess(runtime, node);
    case ASTType.AST_LIST_ACCESS:
      return await visitListAccess(runtime, node);
    case ASTType.AST_ITERATE:
      return await visitIterate(runtime, node);
    case ASTType.AST_ASSERT:
      return await visitAssert(runtime, node);
    case ASTType.AST_ANY:
      return node;
    default:
      throw UncaughtStatementException('Uncaught statement ${node.type}');
  }
}

bool boolEval(ASTNode node) {
  switch (node.runtimeType) {
    case IntNode:
      return node.intVal > 0;
    case DoubleNode:
      return node.doubleVal > 0;
    case BoolNode:
      return node.boolVal;
    case StringNode:
      return node.stringValue.isNotEmpty;
    case MapNode:
      return node.map.isNotEmpty;
    case ListNode:
      return node.listElements.isNotEmpty;
    default:
      return false;
  }
}

Future<ASTNode> getVarDefByName(
    Runtime runtime, Scope scope, String varName) async {
  if (scope.owner != null) {
    if (varName == 'nest') {
      if (scope.owner.parent != null) {
        return scope.owner.parent;
      }

      return scope.owner;
    }
  }
  for (int i = 0; i < scope.variableDefinitions.length; i++) {
    ASTNode varDef = scope.variableDefinitions[i];

    if (varDef.variableName == varName) {
      return varDef;
    }
  }

  return null;
}

Future<ASTNode> visitVariable(Runtime runtime, ASTNode node) async {
  
  var localScope = node.scope;
  var globalScope = runtime.scope;

  if (node.classChildren != null && node.classChildren.isNotEmpty) {
    for (int i = 0; i < node.classChildren.length; i++) {
      ASTNode objectVarDef = node.classChildren[i];

      if (objectVarDef.type != ASTType.AST_VARIABLE_DEFINITION) {
        continue;
      }

      if (objectVarDef.variableName == node.variableName) {
        if (objectVarDef.variableValue == null) {
          return objectVarDef;
        }

        var value = await visit(runtime, objectVarDef.variableValue);
        value.typeValue = objectVarDef.variableType.typeValue;

        return value;
      }
    }
  } else if (node.enumElements != null && node.enumElements.isNotEmpty) {
    for (int i = 0; i < node.enumElements.length; i++) {
      ASTNode variable = node.enumElements[i];

      if (variable.variableName == node.variableName) {
        if (variable.ast != null) {
          return variable.ast;
        } else {
          var intAST = IntNode();
          intAST.intVal = i;
          variable.ast = intAST;

          return variable.ast;
        }
      }
    }
  }

  if (localScope != null) {
    var varDef = await getVarDefByName(runtime, localScope, node.variableName);

    if (varDef != null) {
      if (varDef.type != ASTType.AST_VARIABLE_DEFINITION) return varDef;

      var value = await visit(runtime, varDef.variableValue);
      value.typeValue = varDef.variableType.typeValue;

      return value;
    }

    for (int i = 0; i < localScope.functionDefinitions.length; i++) {
      ASTNode funcDef = localScope.functionDefinitions[i];

      if (funcDef.funcName == node.variableName) {
        return funcDef;
      }
    }
  }

  if (!node.isClassChild && globalScope != null) {
    var varDef = await getVarDefByName(runtime, globalScope, node.variableName);

    if (varDef != null) {
      if (varDef.type != ASTType.AST_VARIABLE_DEFINITION) {
        return varDef;
      }

      var value = await visit(runtime, varDef.variableValue);
      value.typeValue = varDef.variableType.typeValue;

      return value;
    }

    for (int i = 0; i < globalScope.functionDefinitions.length; i++) {
      ASTNode funcDef = globalScope.functionDefinitions[i];

      if (funcDef.funcName == node.variableName) {
        return funcDef;
      }
    }
  }

  String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

  for (Map item in runtime.stack.reversed.take(5))
    stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

  throw UndefinedVariableException(
      'Error: [Line ${node.lineNum}] Undefined variable `${node.variableName}`.$stacktrace');
}

Future<ASTNode> visitVarDef(Runtime runtime, ASTNode node) async {
  
  if (node.scope == runtime.scope) {
    var varDefGlobal =
        await getVarDefByName(runtime, runtime.scope, node.variableName);

    if (varDefGlobal != null) {
      multipleVariableDefinitionsError(node.lineNum, node.variableName);
    }
  }

  if (node.scope != null) {
    var varDefLocal =
        await getVarDefByName(runtime, node.scope, node.variableName);

    if (varDefLocal != null) {
      multipleVariableDefinitionsError(node.lineNum, node.variableName);
    }
  }

  if (node.savedFuncCall != null) {
    node.variableValue = await visit(runtime, node.savedFuncCall);
  } else {
    if (node.variableValue != null) {
      if (node.variableValue.type == ASTType.AST_FUNC_CALL) {
        node.savedFuncCall = node.variableValue;
      }

      node.variableValue = await visit(runtime, node.variableValue);
    } else {
      node.variableValue = NullNode();
    }
  }
  getScope(runtime, node).variableDefinitions.add(node);

  return node.variableValue ?? node;
}

Future<ASTNode> visitVarAssignment(Runtime runtime, ASTNode node) async {
  var left = node.variableAssignmentLeft;
  var localScope = node.scope;
  var globalScope = runtime.scope;

  if (node.classChildren != null && node.classChildren.isNotEmpty) {
    for (int i = 0; i < node.classChildren.length; i++) {
      ASTNode objectVarDef = node.classChildren[i];

      if (objectVarDef.type != ASTType.AST_VARIABLE_DEFINITION) {
        continue;
      }

      if (objectVarDef.variableName == left.variableName) {
        var value = await visit(runtime, node.variableValue);

        if (value.type == ASTType.AST_DOUBLE) {
          value.intVal = value.doubleVal.toInt();
        }
        if (objectVarDef.isFinal) {
          String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

          for (Map item in runtime.stack.reversed.take(5))
            stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

          throw ReassigningFinalVariableException(
              'Error [Line ${node
                  .lineNum}] Cannot reassign final variable `${node
                  .variableAssignmentLeft.variableName}`$stacktrace');
        }
        objectVarDef.variableValue = value;
        return value;
      }
    }
  }

  if (localScope != null) {
    var varDef = await getVarDefByName(runtime, localScope, left.variableName);

    if (varDef != null) {
      var value = await visit(runtime, node.variableValue);
      if (value.type == ASTType.AST_DOUBLE) {
        value.intVal = value.doubleVal.toInt();
      }
      if (varDef.isFinal) {
        String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

        for (Map item in runtime.stack.reversed.take(5))
          stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

        throw ReassigningFinalVariableException(
            'Error [Line ${node.lineNum}] Cannot reassign final variable `${node.variableAssignmentLeft.variableName}`$stacktrace');
      }

      varDef.variableValue = value;
      return value;
    }
  }

  if (globalScope != null) {
    var varDef = await getVarDefByName(runtime, globalScope, left.variableName);

    if (varDef != null) {
      var value = await visit(runtime, node.variableValue);

      if (value == null) return null;
      if (value.type == ASTType.AST_DOUBLE) {
        value.intVal = value.doubleVal.toInt();
      }
      if (varDef.isFinal) {
        String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

        for (Map item in runtime.stack.reversed.take(5))
          stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';
        throw ReassigningFinalVariableException(
            'Error [Line ${node.lineNum}] Cannot reassign final variable `${node.variableAssignmentLeft.variableName}`$stacktrace');
      }

      varDef.variableValue = value;

      return value;
    }
  }
  String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

  for (Map item in runtime.stack.reversed.take(5))
    stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

  throw AssigningUndefinedVariableException(
      "Error: [Line ${left.lineNum}] Can't set undefined variable ${left.variableName}$stacktrace");
}

Future<ASTNode> visitVarMod(Runtime runtime, ASTNode node) async {

  ASTNode value;

  var left = node.binaryOpLeft;
  var varScope = getScope(runtime, node);

  for (int i = 0; i < varScope.variableDefinitions.length; i++) {
    ASTNode astVarDef = varScope.variableDefinitions[i];

    if (node.classChildren != null) {
      for (int i = 0; i < node.classChildren.length; i++) {
        ASTNode objectVarDef = node.classChildren[i];

        if (objectVarDef.type != ASTType.AST_VARIABLE_DEFINITION) continue;

        if (objectVarDef.variableName == left.variableName) {
          astVarDef = objectVarDef;
          break;
        }
      }
    }

    if (left == null) {
      switch (node.binaryOperator.type) {
        case TokenType.TOKEN_PLUS_PLUS:
          {
            ASTNode variable = await visitVariable(runtime, node.binaryOpRight);
            if (variable.type == ASTType.AST_INT)
              return variable..intVal += 1;
            else
              return variable..doubleVal += 1;
          }
          break;

        case TokenType.TOKEN_SUB_SUB:
          {
            ASTNode variable = await visitVariable(runtime, node.binaryOpRight);
            if (variable.type == ASTType.AST_INT)
              return variable..intVal -= 1;
            else
              return variable..doubleVal -= 1;
          }
          break;
        case TokenType.TOKEN_MUL_MUL:
          {
            ASTNode variable = await visitVariable(runtime, node.binaryOpRight);
            if (variable.type == ASTType.AST_INT)
              return variable..intVal *= variable.intVal;
            else
              return variable..doubleVal *= variable.doubleVal;
          }
          break;
        default:
          String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

          for (Map item in runtime.stack.reversed.take(5))
            stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

          throw NoLeftValueException(
              'Error: [Line ${node.lineNum}] No left value provided$stacktrace');
      }
    }
    if (astVarDef.variableName == left.variableName) {
      value = await visit(runtime, node.binaryOpRight);

      switch (node.binaryOperator.type) {
        case TokenType.TOKEN_PLUS_PLUS:
          {
            ASTNode variable = await visitVariable(runtime, left);
            if (variable.typeValue.type == DATATYPE.DATA_TYPE_INT) {
              return variable..intVal += 1;
            } else if (variable.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              return variable..doubleVal += 1;
            }
          }
          break;
        case TokenType.TOKEN_SUB_SUB:
          {
            ASTNode variable = await visitVariable(runtime, left);

            if (variable.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_INT) {
              return variable..intVal -= 1;
            } else if (variable.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              return variable..doubleVal -= 1;
            }
          }
          break;
        case TokenType.TOKEN_MUL_MUL:
          {
            ASTNode variable = await visitVariable(runtime, left);
            if (variable.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_INT) {
              return variable..intVal *= variable.intVal;
            } else if (variable.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              return variable..doubleVal *= variable.intVal;
            }
          }
          break;
        case TokenType.TOKEN_PLUS_EQUAL:
          {
            if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_INT) {
              astVarDef.variableValue.intVal +=
                  value.intVal ?? value.doubleVal.toInt();

              astVarDef.variableValue.doubleVal +=
                  astVarDef.variableValue.intVal;
            } else if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              astVarDef.variableValue.doubleVal +=
                  value.doubleVal ?? value.intVal;
              astVarDef.variableValue.intVal +=
                  astVarDef.variableValue.doubleVal.toInt();
            } else if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_STRING) {
              astVarDef.variableValue.stringValue += value.stringValue;
            }
            return astVarDef.variableValue;
          }
          break;

        case TokenType.TOKEN_SUB_EQUAL:
          {
            if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_INT) {
              astVarDef.variableValue.intVal -=
                  value.intVal ?? value.doubleVal.toInt();
              astVarDef.variableValue.doubleVal -=
                  astVarDef.variableValue.intVal;
              return astVarDef.variableValue;
            } else if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              astVarDef.variableValue.doubleVal -=
                  value.doubleVal ?? value.intVal;
              astVarDef.variableValue.intVal -=
                  astVarDef.variableValue.doubleVal.toInt();
              return astVarDef.variableValue;
            }
          }
          break;

        case TokenType.TOKEN_MUL_EQUAL:
          {
            if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_INT) {
              astVarDef.variableValue.intVal *=
                  value.intVal ?? value.doubleVal.toInt();
              astVarDef.variableValue.doubleVal *=
                  astVarDef.variableValue.intVal;
              return astVarDef.variableValue;
            } else if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              astVarDef.variableValue.doubleVal *=
                  value.doubleVal ?? value.intVal;
              astVarDef.variableValue.intVal *=
                  astVarDef.variableValue.doubleVal.toInt();
              return astVarDef.variableValue;
            }
          }
          break;
        case TokenType.TOKEN_DIV_EQUAL:
          {
            if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              astVarDef.variableValue.doubleVal /=
                  value.doubleVal ?? value.intVal;
              return astVarDef.variableValue;
            }
          }
          break;

        case TokenType.TOKEN_MOD_EQUAL:
          {
            if (astVarDef.variableType.typeValue.type ==
                DATATYPE.DATA_TYPE_DOUBLE) {
              astVarDef.variableValue.intVal %= value.doubleVal ?? value.intVal;
              return astVarDef.variableValue;
            }
          }
          break;

        default:
          String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

          for (Map item in runtime.stack.reversed.take(5))
            stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

          throw InvalidOperatorException(
              'Error: [Line ${node.lineNum}] `${node.binaryOperator.value}` is not a valid operator$stacktrace');
      }
    }
  }
  String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

  for (Map item in runtime.stack.reversed.take(5))
    stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

  throw AssigningUndefinedVariableException(
      "Error: [Line ${node.lineNum}] Can't set undefined variable `${node.variableName}`$stacktrace");
}

Future<ASTNode> visitFuncDef(Runtime runtime, ASTNode node) async {
  var scope = getScope(runtime, node);
  scope.functionDefinitions.add(node);

  return node;
}

Future<ASTNode> runtimeFuncLookup(
    Runtime runtime, Scope scope, ASTNode node) async {
  
  ASTNode funcDef;

  var visitedExpr = await visit(runtime, node.funcCallExpression);

  if (visitedExpr.type == ASTType.AST_FUNC_DEFINITION)
    funcDef = await visitedExpr;

  if (funcDef == null) return null;

  if (funcDef.futureFuncPointer != null) {
    var visitedFuncPointerArgs = [];

    for (int i = 0; i < node.funcCallArgs.length; i++) {
      ASTNode astArg = node.funcCallArgs[i];
      ASTNode visited;

      if (astArg.type == ASTType.AST_VARIABLE) {
        var vDef = await getVarDefByName(
            runtime, getScope(runtime, astArg), astArg.variableName);

        if (vDef != null) visited = vDef.variableValue;
      }

      visited = visited ?? await visit(runtime, astArg);
      await visitedFuncPointerArgs.add(visited);
    }

    var ret = await visit(
        runtime,
        await funcDef.futureFuncPointer(
            runtime, funcDef, await visitedFuncPointerArgs));

    return ret;
  }

  if (funcDef.funcPointer != null) {
    var visitedFuncPointerArgs = [];

    for (int i = 0; i < node.funcCallArgs.length; i++) {
      ASTNode astArg = node.funcCallArgs[i];
      ASTNode visited;

      if (astArg.type == ASTType.AST_VARIABLE) {
        var vDef = await getVarDefByName(
            runtime, getScope(runtime, astArg), astArg.variableName);

        if (vDef != null) visited = vDef.variableValue;
      }

      visited = visited ?? await visit(runtime, astArg);
      await visitedFuncPointerArgs.add(visited);
    }

    var ret = await visit(runtime,
        funcDef.funcPointer(runtime, funcDef, await visitedFuncPointerArgs));

    return ret;
  }

  if (funcDef.funcDefBody != null)
    return await runtimeFuncCall(runtime, node, funcDef);
  else if (funcDef.compChildren != null) {
    var finalRes = ASTNode();
    var dataType = funcDef.funcDefType.typeValue.type;

    if (dataType == DATATYPE.DATA_TYPE_INT) {
      finalRes = IntNode();
    } else if (dataType == DATATYPE.DATA_TYPE_DOUBLE) {
      finalRes = DoubleNode();
    } else if (dataType == DATATYPE.DATA_TYPE_STRING) {
      finalRes = StringNode();
    } else if (dataType == DATATYPE.DATA_TYPE_STRING_BUFFER) {
      finalRes = StrBufferNode();
    }

    var callArgs = [];
    callArgs.add(finalRes);

    for (int i = 0; i < funcDef.compChildren.length; i++) {
      ASTNode compChild = funcDef.compChildren[i];

      ASTNode res;

      if (compChild.type == ASTType.AST_FUNC_DEFINITION) {
        if (i == 0)
          node.funcCallArgs = node.funcCallArgs;
        else
          node.funcCallArgs = callArgs;

        res = await runtimeFuncCall(runtime, node, compChild);
      } else {
        var fCall = FuncCallNode();
        fCall.funcCallExpression = compChild;

        if (i == 0)
          fCall.funcCallArgs = node.funcCallArgs;
        else
          fCall.funcCallArgs = callArgs;

        res = await runtimeFuncLookup(runtime, scope, fCall);
      }

      switch (res.type) {
        case ASTType.AST_INT:
          finalRes.intVal = res.intVal;
          break;
        case ASTType.AST_DOUBLE:
          finalRes.doubleVal = res.doubleVal;
          break;
        case ASTType.AST_STRING:
          finalRes.stringValue = res.stringValue;
          break;
        default:
          break;
      }
    }
    return finalRes;
  }
  return null;
}

Future<ASTNode> visitFuncCall(Runtime runtime, ASTNode node) async {
  runtime.stack.add({'line': node.lineNum, 'function': node.funcCallExpression.variableName});

  if (node.scope != null) {
    var localScopeFuncDef = await runtimeFuncLookup(runtime, node.scope, node);

    if (localScopeFuncDef != null) return localScopeFuncDef;
  }

  var globalScopeFuncDef =
      await runtimeFuncLookup(runtime, runtime.scope, node);
  if (globalScopeFuncDef != null) return globalScopeFuncDef;

  String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

  for (Map item in runtime.stack.reversed.take(5))
    stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

  throw UndefinedVariableException(
      'Error: [Line ${node.lineNum}] Undefined method `?`$stacktrace');
}

Future<ASTNode> visitCompound(Runtime runtime, ASTNode node) async {

  var scope = getScope(runtime, node);
  var oldDefList = [];

  for (int i = 0; i < scope.variableDefinitions.length; i++) {
    ASTNode varDef = scope.variableDefinitions[i];
    oldDefList.add(varDef);
  }

  for (int i = 0; i < node.compoundValue.length; i++) {
    ASTNode child = node.compoundValue[i];

    if (child == null) continue;

    ASTNode visited = await visit(runtime, child);
    if (visited != null) {
      if (visited.type == ASTType.AST_RETURN) {
        if (visited.returnValue != null) {
          var retVal = await visit(runtime, await visited.returnValue);

          collectAndSweepGarbage(runtime, oldDefList, scope);
          return retVal;
        } else {
          collectAndSweepGarbage(runtime, oldDefList, scope);
          return null;
        }
      } else if (visited.type == ASTType.AST_BREAK ||
          visited.type == ASTType.AST_CONTINUE) {
        return visited;
      }
    }
  }

  collectAndSweepGarbage(runtime, oldDefList, scope);
  return node;
}

Future<ASTNode> visitAttAccess(Runtime runtime, ASTNode node) async {
  
  if (node.classChildren != null)
    node.binaryOpLeft.classChildren = node.classChildren;

  if (node.binaryOpRight != null &&
      node.binaryOpLeft.type == ASTType.AST_FUNC_CALL &&
      node.binaryOpRight.type == ASTType.AST_FUNC_CALL) {
    return visit(runtime, node.binaryOpLeft).then((value) async {
      return await visit(runtime, node.binaryOpRight.funcCallArgs[0]);
    });
  } else {
    var left = await visit(runtime, node.binaryOpLeft);
    // TODO (Calamity): Handle Maps, ints and doubles + use a switch

    switch (left.type) {
      case ASTType.AST_LIST:
        if (node.binaryOpRight.type == ASTType.AST_VARIABLE)
          return visitListProperties(node, left);
        break;
      case ASTType.AST_STRING:
        if (node.binaryOpRight.type == ASTType.AST_VARIABLE)
          return visitStringProperties(node, left);
        else if (node.binaryOpRight.type == ASTType.AST_FUNC_CALL)
          return visitStringMethods(node, left);
        break;
      case ASTType.AST_STRING_BUFFER:
        if (node.binaryOpRight.type == ASTType.AST_VARIABLE)
          return visitStrBufferProperties(node, left);
        else if (node.binaryOpRight.type == ASTType.AST_FUNC_CALL)
          return visitStrBufferMethods(node, left);
        break;
      case ASTType.AST_INT:
        if (node.binaryOpRight.type == ASTType.AST_VARIABLE)
          return visitIntProperties(node, left);
        else if (node.binaryOpRight.type == ASTType.AST_FUNC_CALL)
          return visitIntMethods(node, left);
        break;
      case ASTType.AST_DOUBLE:
        if (node.binaryOpRight.type == ASTType.AST_VARIABLE)
          return visitDoubleProperties(node, left);
        else if (node.binaryOpRight.type == ASTType.AST_FUNC_CALL)
          return visitDoubleMethods(node, left);
        break;
      case ASTType.AST_MAP:
        // TODO(Calamity210): Handle this case.
        break;
      case ASTType.AST_BOOL:
        // TODO(Calamity210): Handle this case.
        break;
      case ASTType.AST_CLASS:
        ASTNode binOpRight = node.binaryOpRight;
        if (binOpRight.type == ASTType.AST_VARIABLE ||
            binOpRight.type == ASTType.AST_VARIABLE_ASSIGNMENT ||
            binOpRight.type == ASTType.AST_VARIABLE_MODIFIER ||
            binOpRight.type == ASTType.AST_ATTRIBUTE_ACCESS) {
          binOpRight.classChildren = left.classChildren;
          binOpRight.scope = left.scope;
          binOpRight.isClassChild = true;
          node.classChildren = left.classChildren;
          node.scope = left.scope;
        }
        break;
      case ASTType.AST_LIST_ACCESS:
        node.binaryOpRight.binaryOpLeft.classChildren = left.classChildren;
        node.binaryOpRight.binaryOpLeft.scope = left.scope;
        node.binaryOpRight.binaryOpLeft.isClassChild = true;
        node.binaryOpRight.classChildren = left.classChildren;
        node.binaryOpRight.scope = left.scope;
        break;
      case ASTType.AST_ENUM:
        if (node.binaryOpRight.type == ASTType.AST_VARIABLE) {
          node.binaryOpRight.enumElements = left.enumElements;
          node.binaryOpRight.scope = left.scope;
          node.enumElements = left.enumElements;
          node.scope = left.scope;
        }
        break;
      default:
        String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

        for (Map item in runtime.stack.reversed.take(5))
          stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

        throw UnexpectedTokenException(
            'Error [Line ${node.lineNum}]: Cannot access attribute for Type `${node.type.toString()}`$stacktrace');
        break;
    }

    if (node.binaryOpRight.type == ASTType.AST_FUNC_CALL) {
      if (node.binaryOpRight.funcCallExpression.type == ASTType.AST_VARIABLE) {
        var funcCallName = node.binaryOpRight.funcCallExpression.variableName;

        if (left.funcDefinitions != null) {
          for (int i = 0; i < left.funcDefinitions.length; i++) {
            ASTNode fDef = left.funcDefinitions[i];

            if (fDef.funcName == funcCallName) {
              if (fDef.funcPointer != null) {
                var visitedFuncPointerArgs = [];

                for (int j = 0;
                    j < node.binaryOpRight.funcCallArgs.length;
                    j++) {
                  ASTNode astArg = node.binaryOpRight.funcCallArgs[j];
                  var visited = await visit(runtime, astArg);
                  await visitedFuncPointerArgs.add(visited);
                }

                return await visit(
                    runtime,
                    fDef.funcPointer(
                        runtime, left, await visitedFuncPointerArgs));
              }
            }
          }
        }

        if (left.classChildren != null) {
          for (int i = 0; i < left.classChildren.length; i++) {
            ASTNode objChild = left.classChildren[i];

            if (objChild.type == ASTType.AST_FUNC_DEFINITION) if (objChild
                    .funcName ==
                funcCallName)
              return await runtimeFuncCall(
                  runtime, node.binaryOpRight, objChild);
          }
        }
      }
    }

    node.scope = getScope(runtime, left);

    ASTNode newAST = await visit(runtime, node.binaryOpRight);

    return await visit(runtime, newAST);
  }
}

Future<ASTNode> visitListAccess(Runtime runtime, ASTNode node) async {
  
  var left = await visit(runtime, node.binaryOpLeft);
  ASTNode ast = await visit(runtime, node.listAccessPointer);

  if (ast.type == ASTType.AST_STRING) {
    var key = ast.stringValue;
    if (left.type != ASTType.AST_MAP) {
      String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

      for (Map item in runtime.stack.reversed.take(5))
        stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

      throw UnexpectedTypeException(
          'Error: [Line ${node.lineNum}] Expected a Map$stacktrace');
    }

    if (left.map.containsKey(key)) {
      if (left.map[key] is String) {
        ASTNode mapValAST = StringNode()..stringValue = left.map[key];
        return mapValAST;
      }
      return left.map[key];
    } else
      return null;
  } else {
    var index = ast.intVal;
    if (left.type == ASTType.AST_LIST) if (left.listElements.isNotEmpty &&
        index < left.listElements.length) {
      if (left.listElements[index] is Map) {
        var type = initDataTypeAs(DATATYPE.DATA_TYPE_MAP);
        ASTNode mapAst = MapNode()
          ..typeValue = type
          ..scope = left.scope
          ..map = left.listElements[index];

        return mapAst;
      } else if (left.listElements[index] is String) {
        var type = initDataTypeAs(DATATYPE.DATA_TYPE_STRING);
        ASTNode stringAst = StringNode()
          ..typeValue = type
          ..scope = left.scope
          ..stringValue = left.listElements[index];

        return stringAst;
      }
      return left.listElements[index];
    } else {
      String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

      for (Map item in runtime.stack.reversed.take(5))
        stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

      throw RangeException(
          'Error: Invalid list index: Valid range is: ${left.listElements.isNotEmpty ? left.listElements.length - 1 : 0}$stacktrace');
    }

    String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

    for (Map item in runtime.stack.reversed.take(5))
      stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

    throw UnexpectedTypeException('List Access left value is not iterable.$stacktrace');
  }
}

Future<ASTNode> visitBinaryOp(Runtime runtime, ASTNode node) async {
  
  ASTNode retVal;
  var left = await visit(runtime, node.binaryOpLeft);
  var right = node.binaryOpRight;

  if (node.binaryOperator.type == TokenType.TOKEN_DOT) {
    String accessName;

    if (right.type == ASTType.AST_VARIABLE) accessName = right.variableName;

    if (right.type == ASTType.AST_BINARYOP) right = await visit(runtime, right);

    if (left.type == ASTType.AST_CLASS) {
      for (int i = 0; i < left.classChildren.length; i++) {
        var child = await visit(runtime, left.classChildren[i] as ASTNode);

        if (child.type == ASTType.AST_VARIABLE_DEFINITION &&
            child.type == ASTType.AST_VARIABLE_ASSIGNMENT) {
          child.variableValue = await visit(runtime, right.variableValue);
          return child.variableValue;
        }

        if (child.type == ASTType.AST_VARIABLE_DEFINITION) {
          if (child.variableName == accessName) {
            if (child.variableValue != null)
              return await visit(runtime, child.variableValue);
            else
              return child;
          }
        } else if (child.type == ASTType.AST_FUNC_DEFINITION) {
          if (child.funcName == accessName) {
            for (int j = 0; j < right.funcCallArgs.length; j++) {
              ASTNode astArg = right.funcCallArgs[j];

              if (j > child.funcDefArgs.length - 1) {
                print(
                    'Error: [Line ${astArg.lineNum}] Too many arguments for function `$accessName`');
                break;
              }

              ASTNode astFDefArg = child.funcDefArgs[j];
              String argName = astFDefArg.variableName;

              var newVarDef = VarDefNode();
              newVarDef.variableValue = await visit(runtime, astArg);
              newVarDef.variableName = argName;

              getScope(runtime, child.funcDefBody)
                  .variableDefinitions
                  .add(newVarDef);
            }

            return await visit(runtime, child.funcDefBody);
          }
        }
      }
    }
  }

  right = await visit(runtime, right);

  switch (node.binaryOperator.type) {
    case TokenType.TOKEN_PLUS:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode();

          retVal.intVal = left.intVal + right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal + right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.intVal + right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_INT) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal + right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_STRING &&
            right.type == ASTType.AST_STRING) {
          retVal = StringNode();

          retVal.stringValue = left.stringValue + right.stringValue;

          return retVal;
        }

        if (left.type == ASTType.AST_STRING && right.type == ASTType.AST_INT) {
          retVal = StringNode();

          retVal.stringValue = left.stringValue + right.intVal.toString();

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_STRING) {
          retVal = StringNode();

          retVal.stringValue = left.intVal.toString() + right.stringValue;

          return retVal;
        }
        if (left.type == ASTType.AST_STRING &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = StringNode();

          retVal.stringValue = left.stringValue + right.doubleVal.toString();

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_STRING) {
          retVal = StringNode();

          retVal.stringValue = left.doubleVal.toString() + right.stringValue;

          return retVal;
        }
      }

      break;

    case TokenType.TOKEN_SUB:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode();

          retVal.intVal = left.intVal - right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal - right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.intVal - right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_INT) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal - right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_MUL:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode();

          retVal.intVal = left.intVal * right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal * right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.intVal * right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_INT) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal * right.intVal;

          return retVal;
        }

        if (left.type == ASTType.AST_STRING && right.type == ASTType.AST_INT) {
          retVal = StringNode();

          retVal.stringValue = left.stringValue * right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_DIV:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = DoubleNode();

          retVal.doubleVal = left.intVal / right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal / right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_DOUBLE) {
          retVal = DoubleNode();

          retVal.doubleVal = left.intVal / right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_INT) {
          retVal = DoubleNode();

          retVal.doubleVal = left.doubleVal / right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_AND:
      {
        if (left.type == ASTType.AST_BOOL && right.type == ASTType.AST_BOOL) {
          retVal = BoolNode();

          retVal.boolVal = left.boolVal && right.boolVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_OR:
      {
        if (left.type == ASTType.AST_BOOL && right.type == ASTType.AST_BOOL) {
          retVal = BoolNode();

          retVal.boolVal = left.boolVal || right.boolVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_LESS_THAN:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal < right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal < right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_DOUBLE) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal < right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_INT) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal < right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_GREATER_THAN:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal > right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal > right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_DOUBLE) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal > right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_INT) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal > right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_BITWISE_AND:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode()..intVal = left.intVal & right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_BITWISE_OR:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode()..intVal = left.intVal | right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_BITWISE_XOR:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode()..intVal = left.intVal ^ right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_LSHIFT:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode()..intVal = left.intVal << right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_RSHIFT:
      {
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = IntNode()..intVal = left.intVal >> right.intVal;

          return retVal;
        }
      }
      break;

    case TokenType.TOKEN_EQUALITY:
      {
        if (left is BoolNode && right is BoolNode) {
          retVal = BoolNode()..boolVal = left.boolVal == right.boolVal;

          return retVal;
        }

        if (left is BoolNode && right is IntNode) {
          retVal = BoolNode();

          if (right.intVal != 1 && right.intVal != 0) {
            String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

            for (Map item in runtime.stack.reversed.take(5))
              stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

            throw UnexpectedTokenException(
                'Only integer literals `0` and `1` can be compared with a bool$stacktrace');
          }

          retVal.boolVal = left.boolVal == (right.intVal == 1);

          return retVal;
        }

        if (left is BoolNode && right is NullNode) {
          retVal = BoolNode();

          retVal.boolVal = left.boolVal == null;

          return retVal;
        }

        if (left is IntNode && right is BoolNode) {
          if (left.intVal != 1 && left.intVal != 0) {
            String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

            for (Map item in runtime.stack.reversed.take(5))
              stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

            throw UnexpectedTokenException(
                'Only integer literals `0` and `1` can be compared with a bool$stacktrace');
          }

          retVal = BoolNode();

          retVal.boolVal = (left.intVal == 1) == right.boolVal;

          return retVal;
        }

        if (left is IntNode && right is IntNode) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal == right.intVal;

          return retVal;
        }
        if (left is DoubleNode && right is DoubleNode) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal == right.doubleVal;

          return retVal;
        }
        if (left is IntNode && right is DoubleNode) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal == right.doubleVal;

          return retVal;
        }
        if (left is IntNode && right is NullNode) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal == 0 || left.intVal == null;

          return retVal;
        }
        if (left is DoubleNode && right is IntNode) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal == right.intVal;

          return retVal;
        }
        if (left is DoubleNode && right is NullNode) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal == 0 || left.doubleVal == null;

          return retVal;
        }
        if (left is StringNode && right is StringNode) {
          retVal = BoolNode();

          retVal.boolVal = left.stringValue == right.stringValue;

          return retVal;
        }

        if (left is StringNode && right is NullNode) {
          retVal = BoolNode();

          retVal.boolVal = left.stringValue == null;

          return retVal;
        }

        if (left is ClassNode && right is ClassNode) {
          retVal = BoolNode()..boolVal = left.className == right.className;

          var leftChildren =
              left.classChildren.whereType<VarDefNode>().toList();
          var rightChildren =
              right.classChildren.whereType<VarDefNode>().toList();

          if (leftChildren.length != rightChildren.length) {
            retVal.boolVal = false;
            return retVal;
          }

          for (int i = 0; i < leftChildren.length; i++) {
            retVal.boolVal =
                retVal.boolVal && (leftChildren[i] == rightChildren[i]);
          }

          return retVal;
        }

        if (left is ClassNode && right is NullNode) {
          retVal = BoolNode();

          retVal.boolVal = left.classChildren.isEmpty;

          return retVal;
        }

        if (left is NullNode && right is NullNode) {
          retVal = BoolNode();

          retVal.boolVal = true;

          return retVal;
        }
      }
      break;
    case TokenType.TOKEN_NOT_EQUAL:
      {
        if (left is BoolNode && right is BoolNode) {
          retVal = BoolNode();

          retVal.boolVal = left.boolVal != right.boolVal;

          return retVal;
        }

        if (left is BoolNode && right.type == ASTType.AST_INT) {
          retVal = BoolNode();

          if (right.intVal != 1 && right.intVal != 0) {
            String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

            for (Map item in runtime.stack.reversed.take(5))
              stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

            throw UnexpectedTokenException(
                'Only integer literals `0` and `1` can be compared with a bool$stacktrace');
          }

          retVal.boolVal = left.boolVal != (right.intVal == 1);

          return retVal;
        }

        if (left is BoolNode && right is NullNode) {
          retVal = BoolNode();

          retVal.boolVal = left.boolVal == null;

          return retVal;
        }

        if (left.type == ASTType.AST_INT && right is BoolNode) {
          if (left.intVal != 1 && left.intVal != 0) {
            String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

            for (Map item in runtime.stack.reversed.take(5))
              stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

            throw UnexpectedTokenException(
                'Only integer literals `0` and `1` can be compared with a bool.$stacktrace');
          }

          retVal = BoolNode();

          retVal.boolVal = (left.intVal == 1) != right.boolVal;

          return retVal;
        }

        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_INT) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal != right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE &&
            right.type == ASTType.AST_DOUBLE) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal != right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_DOUBLE) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal != right.doubleVal;

          return retVal;
        }
        if (left.type == ASTType.AST_INT && right.type == ASTType.AST_NULL) {
          retVal = BoolNode();

          retVal.boolVal = left.intVal != 0 || left.intVal != null;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_INT) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal != right.intVal;

          return retVal;
        }
        if (left.type == ASTType.AST_DOUBLE && right.type == ASTType.AST_NULL) {
          retVal = BoolNode();

          retVal.boolVal = left.doubleVal != 0 || left.doubleVal != null;

          return retVal;
        }
        if (left.type == ASTType.AST_STRING &&
            right.type == ASTType.AST_STRING) {
          retVal = BoolNode();

          retVal.boolVal = left.stringValue != right.stringValue;

          return retVal;
        }

        if (left.type == ASTType.AST_STRING && right.type == ASTType.AST_NULL) {
          retVal = BoolNode();

          retVal.boolVal = left.stringValue != null;

          return retVal;
        }
        if (left.type == ASTType.AST_CLASS && right.type == ASTType.AST_CLASS) {
          retVal = BoolNode();

          retVal.boolVal = left.classChildren != right.classChildren;

          return retVal;
        }

        if (left.type == ASTType.AST_CLASS && right.type == ASTType.AST_NULL) {
          retVal = BoolNode();

          retVal.boolVal = left.classChildren.isNotEmpty;

          return retVal;
        }

        if (left.type == ASTType.AST_NULL && right.type == ASTType.AST_NULL) {
          retVal = BoolNode();

          retVal.boolVal = false;

          return retVal;
        }
      }
      break;

    default:
      String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

      for (Map item in runtime.stack.reversed.take(5))
        stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

      throw InvalidOperatorException(
          'Error: [Line ${node.lineNum}] `${node.binaryOperator.value}` is not a valid operator.$stacktrace');
  }

  return node;
}

Future<ASTNode> visitUnaryOp(Runtime runtime, ASTNode node) async {
  
  ASTNode right = await visit(runtime, node.unaryOpRight);

  ASTNode returnValue = INITIALIZED_NOOP;

  switch (node.unaryOperator.type) {
    case TokenType.TOKEN_ONES_COMPLEMENT:
      {
        if (right.type == ASTType.AST_INT) {
          returnValue = IntNode()..intVal = ~right.intVal;
        }
      }
      break;
    case TokenType.TOKEN_SUB:
      {
        if (right.type == ASTType.AST_INT) {
          returnValue = IntNode()..intVal = -right.intVal;
        } else if (right.type == ASTType.AST_DOUBLE) {
          returnValue = DoubleNode()..doubleVal = -right.doubleVal;
        }
      }
      break;

    case TokenType.TOKEN_PLUS:
      {
        if (right.type == ASTType.AST_INT) {
          returnValue = IntNode();
          returnValue.intVal = right.intVal.abs();
        } else if (right.type == ASTType.AST_DOUBLE) {
          returnValue = DoubleNode();
          returnValue.doubleVal = right.doubleVal.abs();
        }
      }
      break;

    case TokenType.TOKEN_PLUS_PLUS:
      {
        ASTNode variable = await visitVariable(runtime, node.unaryOpRight);
        if (variable.type == ASTType.AST_INT)
          return variable..intVal += 1;
        else
          return variable..doubleVal += 1;
      }
      break;

    case TokenType.TOKEN_SUB_SUB:
      {
        ASTNode variable = await visitVariable(runtime, node.unaryOpRight);
        if (variable.type == ASTType.AST_INT)
          return variable..intVal -= 1;
        else
          return variable..doubleVal -= 1;
      }
      break;
    case TokenType.TOKEN_MUL_MUL:
      {
        ASTNode variable = await visitVariable(runtime, node.unaryOpRight);
        if (variable.type == ASTType.AST_INT)
          return variable..intVal *= variable.intVal;
        else
          return variable..doubleVal *= variable.doubleVal;
      }
      break;
    case TokenType.TOKEN_NOT:
      {
        ASTNode boolAST = BoolNode();
        switch (node.unaryOpRight.type) {
          case ASTType.AST_VARIABLE:
            {
              boolAST.boolVal =
                  !boolEval(await visitVariable(runtime, node.unaryOpRight));
              return boolAST;
            }
            break;
          default:
            boolAST.boolVal = !boolEval(node.unaryOpRight);
            break;
        }
        break;
      }
      break;

    default:
      String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

      for (Map item in runtime.stack.reversed.take(5))
        stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

      throw InvalidOperatorException(
          'Error: [Line ${node.lineNum}] `${node.unaryOperator.value}` is not a valid operator.$stacktrace');
  }

  return returnValue;
}

Future<ASTNode> visitIf(Runtime runtime, ASTNode node) async {

  if (node.ifExpression == null) {
    String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

    for (Map item in runtime.stack.reversed.take(5))
      stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

    throw UnexpectedTypeException(
        'Error: [Line ${node.lineNum}] If expression can\'t be empty.$stacktrace');
  }

  if (node.ifExpression.type == ASTType.AST_UNARYOP) {
    if (boolEval(await visit(runtime, node.ifExpression.unaryOpRight)) ==
        false) {
      return await visit(runtime, node.ifBody);
    } else {
      if (node.ifElse != null) return await visit(runtime, node.ifElse);

      if (node.elseBody != null) return await visit(runtime, node.elseBody);
    }
  } else {
    if (boolEval(await visit(runtime, node.ifExpression))) {
      return await visit(runtime, node.ifBody);
    } else {
      if (node.ifElse != null) return await visit(runtime, node.ifElse);

      if (node.elseBody != null) return await visit(runtime, node.elseBody);
    }
  }
  return node;
}

Future<ASTNode> visitSwitch(Runtime runtime, ASTNode node) async {
  
  if (node.switchExpression == null) {
    String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

    for (Map item in runtime.stack.reversed.take(5))
      stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

    throw UnexpectedTypeException(
        'Error: [Line ${node.lineNum}] Switch expression can\'t be empty$stacktrace');
  }

  ASTNode caseAST = await visit(runtime, node.switchExpression);

  switch (caseAST.type) {
    case ASTType.AST_STRING:
      Iterable<ASTNode> testCase = node.switchCases.keys
          .where((element) => element.stringValue == caseAST.stringValue);

      if (testCase != null && testCase.isNotEmpty) {
        return await visit(runtime, node.switchCases[testCase.first]);
      }
      return await visit(runtime, node.switchDefault);
    case ASTType.AST_INT:
      Iterable<ASTNode> testCase = node.switchCases.keys
          .where((element) => element.intVal == caseAST.intVal);

      if (testCase != null && testCase.isNotEmpty) {
        return await visit(runtime, node.switchCases[testCase.first]);
      }
      return await visit(runtime, node.switchDefault);
    case ASTType.AST_DOUBLE:
      Iterable<ASTNode> testCase = node.switchCases.keys
          .where((element) => element.doubleVal == caseAST.doubleVal);

      if (testCase != null && testCase.isNotEmpty) {
        return await visit(runtime, node.switchCases[testCase.first]);
      }
      return await visit(runtime, node.switchDefault);
    case ASTType.AST_MAP:
      Iterable<ASTNode> testCase =
          node.switchCases.keys.where((element) => element.map == caseAST.map);

      if (testCase != null && testCase.isNotEmpty) {
        return await visit(runtime, node.switchCases[testCase.first]);
      }
      return await visit(runtime, node.switchDefault);
    case ASTType.AST_LIST:
      Iterable<ASTNode> testCase = node.switchCases.keys
          .where((element) => element.listElements == caseAST.listElements);

      if (testCase != null && testCase.isNotEmpty) {
        return await visit(runtime, node.switchCases[testCase.first]);
      }
      return await visit(runtime, node.switchDefault);
    default:
      return await visit(runtime, node.switchDefault);
  }
}

Future<ASTNode> visitTernary(Runtime runtime, ASTNode node) async {

  return boolEval(await visit(runtime, node.ternaryExpression))
      ? await visit(runtime, node.ternaryBody)
      : await visit(runtime, node.ternaryElseBody);
}

Future<ASTNode> visitWhile(Runtime runtime, ASTNode node) async {

  while (boolEval(await visit(runtime, node.whileExpression))) {
    var visited = await visit(runtime, node.whileBody);

    if (visited.type == ASTType.AST_BREAK) break;
    else if (visited.type == ASTType.AST_CONTINUE) continue;
  }

  return node;
}

Future<ASTNode> visitFor(Runtime runtime, ASTNode node) async {

  await visit(runtime, node.forInitStatement);

  while (boolEval(await visit(runtime, node.forConditionStatement))) {
    var visited = await visit(runtime, node.forBody);

    if (visited is BreakNode) break;
    else if (visited is ContinueNode) {
    await visit(runtime, node.forChangeStatement);
    continue;
    }
    await visit(runtime, node.forChangeStatement);
  }

  return node;
}

Future<ASTNode> visitIterate(Runtime runtime, ASTNode node) async {

  var scope = getScope(runtime, node);
  ASTNode astIterable = await visit(runtime, node.iterateIterable);

  ASTNode fDef;

  if (node.iterateFunction.type == ASTType.AST_FUNC_DEFINITION)
    fDef = node.iterateFunction;

  if (fDef == null) {
    for (int i = 0; i < scope.functionDefinitions.length; i++) {
      fDef = scope.functionDefinitions[i];

      if (fDef.funcName == node.iterateFunction.variableName) {
        if (fDef.funcPointer != null) {
          String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

          for (Map item in runtime.stack.reversed.take(5))
            stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

          throw UnexpectedTypeException(
              'Error: Can not iterate with native method.$stacktrace');
        }
        break;
      }
    }
  }

  var fDefBodyScope = fDef.funcDefBody.scope;
  var iterableVarName = (fDef.funcDefArgs[0] as ASTNode).variableName;

  int i = 0;

  for (int j = fDefBodyScope.variableDefinitions.length - 1; j > 0; j--) {
    fDefBodyScope.variableDefinitions
        .remove(fDefBodyScope.variableDefinitions[j]);
  }

  ASTNode indexVar;

  if (fDef.funcDefArgs.length > 1) {
    indexVar = VarDefNode();
    indexVar.variableValue = IntNode();
    indexVar.variableValue.intVal = i;
    indexVar.variableName = (fDef.funcDefArgs[0] as ASTNode).variableName;

    fDefBodyScope.variableDefinitions.add(indexVar);
  }

  if (astIterable.type == ASTType.AST_STRING) {
    var newVarDef = VarDefNode();
    newVarDef.variableValue = StringNode();
    newVarDef.variableValue.stringValue = astIterable.stringValue[i];
    newVarDef.variableName = iterableVarName;

    fDefBodyScope.variableDefinitions.add(newVarDef);

    for (; i < astIterable.stringValue.length; i++) {
      newVarDef.variableValue.stringValue = astIterable.stringValue[i];

      if (indexVar != null) indexVar.variableValue.intVal = i;

      await visit(runtime, fDef.funcDefBody);
    }
  } else if (astIterable.type == ASTType.AST_LIST) {
    var newVarDef = VarDefNode();
    newVarDef.variableValue = await visit(runtime, astIterable.listElements[i]);
    newVarDef.variableName = iterableVarName;

    fDefBodyScope.variableDefinitions.add(newVarDef);

    for (; i < astIterable.listElements.length; i++) {
      newVarDef.variableValue =
          await visit(runtime, (astIterable.listElements[i] as ASTNode));

      if (indexVar != null) indexVar.variableValue.intVal = i;

      await visit(runtime, fDef.funcDefBody);
    }
  }

  return INITIALIZED_NOOP;
}

Future<ASTNode> visitAssert(Runtime runtime, ASTNode node) async {
  
  ASTNode boolAST = await visit(runtime, node.assertExpression);
  if (!boolEval(boolAST)) {
    String str;

    if (node.assertExpression.type == ASTType.AST_BINARYOP) {
      var left =
          astToString(await visit(runtime, node.assertExpression.binaryOpLeft));
      var right = astToString(
          await visit(runtime, node.assertExpression.binaryOpRight));
      str = 'ASSERT($left, $right)';

      print(str);
    } else {
      var val = astToString(await visit(runtime, node.assertExpression));
      str = val;
      print(val);
    }
    String stacktrace = '\nThe stacktrace when the error was thrown was:\n';

    for (Map item in runtime.stack.reversed.take(5))
      stacktrace += ' [Line:${item['line']}] ${runtime.path}::${item['function']}\n';

    throw AssertionException('Assert failed.$stacktrace');
  }

  return INITIALIZED_NOOP;
}

/// Expect arguments for a function
void runtimeExpectArgs(List inArgs, List<ASTType> args) {
  if (inArgs.length < args.length) {
    throw InvalidArgumentsException(
        '${inArgs.length} argument(s) were provided, while ${args.length} were expected');
  }

  for (int i = 0; i < args.length; i++) {
    if (args[i] == ASTType.AST_ANY) continue;

    ASTNode ast = inArgs[i];

    if (ast.type != args[i]) {
      print('Received argument of type ${ast.type}, but expected ${args[i]}');
      throw InvalidArgumentsException('Got unexpected arguments, terminating');
    }
  }
}
