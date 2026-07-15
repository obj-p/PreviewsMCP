@freestanding(expression)
public macro fixtureStamp() -> String = #externalMacro(
    module: "FixtureMacrosPlugin",
    type: "FixtureStampMacro"
)
